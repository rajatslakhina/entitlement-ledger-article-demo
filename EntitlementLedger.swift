import Foundation

/// A single source of truth for "what does this customer own", folded from every rail.
///
/// The ledger is a value type on purpose. It holds receipts, not opinions: you can
/// hand it to a test, snapshot it, diff two of them, or replay a customer's entire
/// history to answer a support ticket. Nothing in here talks to a network.
///
/// ```swift
/// var ledger = EntitlementLedger(policy: .subscription)
/// ledger.ingest(storeKitEvents + pspWebhookEvents)   // any order, duplicates fine
/// let verdict = ledger.verdict(for: "pro.annual", at: .now)
/// ```
public struct EntitlementLedger: Sendable {

    public let policy: ReconciliationPolicy

    /// Receipts keyed by idempotency key. A dictionary, not an array, because the
    /// rails will send you the same event more than once and that has to be free.
    private var events: [String: ReceiptEvent]

    public init(policy: ReconciliationPolicy = .subscription, events: [ReceiptEvent] = []) {
        self.policy = policy
        self.events = [:]
        ingest(events)
    }

    // MARK: - Ingestion

    /// Records an event. Returns `true` if it was new.
    ///
    /// Re-delivering an event is a no-op. It has to be: a PSP that does not get a
    /// 200 back within its timeout will send the same webhook again, and a refund
    /// applied twice is indistinguishable from a bug in your access control.
    @discardableResult
    public mutating func ingest(_ event: ReceiptEvent) -> Bool {
        guard events[event.id] == nil else { return false }
        events[event.id] = event
        return true
    }

    /// Records many events. Returns how many were new.
    @discardableResult
    public mutating func ingest(_ newEvents: [ReceiptEvent]) -> Int {
        newEvents.reduce(into: 0) { count, event in
            if ingest(event) { count += 1 }
        }
    }

    /// Every event held, in deterministic order.
    public var allEvents: [ReceiptEvent] {
        events.values.sorted(by: ReceiptEvent.isOrderedBefore)
    }

    /// Every product the ledger has ever seen a receipt for.
    public var knownProductIDs: Set<String> {
        Set(events.values.map(\.productID))
    }

    // MARK: - Per-rail fold

    /// The state one rail believes it is in for one product at `date`.
    ///
    /// A rail can only open and close its own grants. That constraint is the whole
    /// point: a chargeback from your PSP must not revoke a subscription the customer
    /// also bought through Apple, and vice versa.
    public func railState(for productID: String, on rail: PaymentRail, at date: Date) -> RailState {
        let relevant = events.values
            .filter { $0.productID == productID && $0.rail == rail && $0.effectiveAt <= date }
            .sorted(by: ReceiptEvent.isOrderedBefore)

        var open: Grant?
        var closure: DenialReason?

        for event in relevant {
            if event.kind.grantsAccess {
                open = Grant(
                    productID: productID,
                    rail: rail,
                    grantedAt: event.effectiveAt,
                    expiresAt: event.expiresAt,
                    sourceEventID: event.id
                )
                closure = nil
            } else if event.kind.closesAccess {
                // Only closes something this rail had opened.
                if open != nil {
                    closure = event.kind == .refund
                        ? .refunded(rail: rail, at: event.effectiveAt)
                        : .revoked(rail: rail, at: event.effectiveAt)
                    open = nil
                }
            }
            // .correction and .abandoned are reportable and entitlement-neutral.
        }

        if let closure { return .closed(closure) }
        guard let open else { return .silent }
        return .open(open)
    }

    /// Every rail holding an open grant for `productID` at `date`, including grants
    /// inside their grace window.
    public func openGrants(for productID: String, at date: Date) -> [Grant] {
        let rails = Set(events.values.filter { $0.productID == productID }.map(\.rail))
        var grants: [Grant] = []
        for rail in rails {
            guard let candidate = railState(for: productID, on: rail, at: date).grant else { continue }
            if candidate.isActive(at: date) || graceEnd(of: candidate).map({ date < $0 }) == true {
                grants.append(candidate)
            }
        }
        return grants.sorted { lhs, rhs in
            lhs.rail.identifier < rhs.rail.identifier
        }
    }

    private func graceEnd(of grant: Grant) -> Date? {
        guard policy.gracePeriod > 0, let expiresAt = grant.expiresAt else { return nil }
        return expiresAt.addingTimeInterval(policy.gracePeriod)
    }

    // MARK: - Verdict

    /// The answer. One verdict, folded across every rail, under the configured policy.
    public func verdict(for productID: String, at date: Date) -> EntitlementVerdict {
        let candidates = openGrants(for: productID, at: date)

        guard let winner = resolve(candidates, at: date) else {
            return .notEntitled(closureReason(for: productID, at: date))
        }

        if winner.isActive(at: date) {
            return .entitled(winner)
        }
        if let graceEnd = graceEnd(of: winner), date < graceEnd {
            return .grace(winner, until: graceEnd)
        }
        return .notEntitled(.expired(at: winner.expiresAt ?? date))
    }

    /// Why there is nothing to grant. Prefers an explicit closure (a refund or a
    /// revocation) over a bare expiry, because those are different conversations
    /// with the customer.
    private func closureReason(for productID: String, at date: Date) -> DenialReason {
        let rails = Set(events.values.filter { $0.productID == productID }.map(\.rail))
            .sorted { $0.identifier < $1.identifier }

        var expiry: Date?
        for rail in rails {
            switch railState(for: productID, on: rail, at: date) {
            case .closed(let reason):
                return reason
            case .open(let grant):
                if let expiresAt = grant.expiresAt {
                    expiry = max(expiry ?? expiresAt, expiresAt)
                }
            case .silent:
                continue
            }
        }
        if let expiry { return .expired(at: expiry) }
        return .noGrant
    }

    /// Picks the grant that decides the verdict.
    ///
    /// A grant that is genuinely active always beats one that is only alive because
    /// of grace, whatever the conflict rule says. Grace is a stay of execution for a
    /// rail that has gone quiet, not a claim that competes with a rail that has not.
    private func resolve(_ grants: [Grant], at date: Date) -> Grant? {
        let active = grants.filter { $0.isActive(at: date) }
        let pool = active.isEmpty ? grants : active

        guard let first = pool.first else { return nil }
        guard pool.count > 1 else { return first }

        let grants = pool
        switch policy.conflictRule {
        case .mostGenerous:
            return grants.max(by: Self.runsShorter) ?? first
        case .strictest:
            return grants.min(by: Self.runsShorter) ?? first
        case .railPriority(let order):
            for rail in order {
                if let match = grants.first(where: { $0.rail == rail }) { return match }
            }
            return grants.max(by: Self.runsShorter) ?? first
        }
    }

    /// Orders grants by how long they run. A non-expiring grant runs longest.
    private static func runsShorter(_ lhs: Grant, _ rhs: Grant) -> Bool {
        switch (lhs.expiresAt, rhs.expiresAt) {
        case (nil, nil): return lhs.rail.identifier < rhs.rail.identifier
        case (nil, _): return false
        case (_, nil): return true
        case (let left?, let right?):
            if left != right { return left < right }
            return lhs.rail.identifier < rhs.rail.identifier
        }
    }

    // MARK: - The metric worth alerting on

    /// Products where more than one rail holds an open grant at `date`.
    ///
    /// This is the number to put on a dashboard. Two open grants for one product
    /// usually means the customer is paying twice — once through Apple, once through
    /// your processor — and neither Apple nor your PSP can see the other side of it.
    /// Nobody will file a bug for this. It just quietly shows up as churn.
    public func dualRailGrants(at date: Date) -> [String: [Grant]] {
        var result: [String: [Grant]] = [:]
        for productID in knownProductIDs.sorted() {
            let grants = openGrants(for: productID, at: date)
            if grants.count > 1 { result[productID] = grants }
        }
        return result
    }
}
