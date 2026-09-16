import Foundation

/// What a receipt event does to the customer's access.
///
/// The five reportable kinds come straight from Apple's reporting requirement for
/// alternative payments: "Required reporting includes refunds, corrections, renewals,
/// one-time purchases, and transactions that didn't result in a purchase."
/// `revocation` is the sixth, because a PSP chargeback is not a refund you issued.
public enum ReceiptEventKind: String, Hashable, Sendable, Codable, CaseIterable {

    /// A one-time purchase, or the first period of a subscription.
    case purchase

    /// A subsequent subscription period.
    case renewal

    /// Money returned to the customer by you or by Apple.
    case refund

    /// Access withdrawn without a refund you initiated — a chargeback, a failed
    /// settlement, a fraud reversal.
    case revocation

    /// An amount or record correction. Reportable, but it never moves entitlement.
    case correction

    /// A transaction that started and did not complete. Reportable — this is the
    /// category teams forget, because nothing happened.
    case abandoned

    /// Whether this kind opens access.
    var grantsAccess: Bool {
        self == .purchase || self == .renewal
    }

    /// Whether this kind closes access that the same rail had opened.
    var closesAccess: Bool {
        self == .refund || self == .revocation
    }
}

/// One normalised receipt from one rail.
///
/// Every rail speaks a different dialect: StoreKit 2 hands you a signed
/// `Transaction`, a PSP posts a JSON webhook, an out-of-app sale may only show up in
/// a nightly settlement file. This is the shape they all get translated into before
/// anything downstream is allowed to reason about them.
public struct ReceiptEvent: Hashable, Sendable, Codable, Identifiable {

    /// The idempotency key. Two events with the same `id` are the same event,
    /// no matter how many times a webhook retries or a settlement file is replayed.
    public let id: String

    /// Which rail this receipt came from.
    public let rail: PaymentRail

    /// The entitlement this receipt is about — your product identifier, not the
    /// rail's SKU. Normalising SKU to product is the integration's job, not the
    /// ledger's.
    public let productID: String

    public let kind: ReceiptEventKind

    /// When this event takes effect in the customer's timeline.
    ///
    /// Deliberately not "when it arrived". Webhooks arrive late, out of order, and
    /// twice; settlement files arrive a day behind. Folding on `effectiveAt` is what
    /// makes the ledger's answer independent of delivery order.
    public let effectiveAt: Date

    /// When the access opened by this event ends. `nil` means it does not expire
    /// (a non-consumable, or a lifetime unlock).
    public let expiresAt: Date?

    /// A per-rail monotonic counter, when the rail provides one. Used only to break
    /// ties between events that share an `effectiveAt`.
    public let railSequence: Int?

    /// The amount, in minor units of `currency`. Carried for reporting, never for
    /// entitlement decisions.
    public let amountMinorUnits: Int?

    /// ISO 4217 code for `amountMinorUnits`.
    public let currency: String?

    public init(
        id: String,
        rail: PaymentRail,
        productID: String,
        kind: ReceiptEventKind,
        effectiveAt: Date,
        expiresAt: Date? = nil,
        railSequence: Int? = nil,
        amountMinorUnits: Int? = nil,
        currency: String? = nil
    ) {
        self.id = id
        self.rail = rail
        self.productID = productID
        self.kind = kind
        self.effectiveAt = effectiveAt
        self.expiresAt = expiresAt
        self.railSequence = railSequence
        self.amountMinorUnits = amountMinorUnits
        self.currency = currency
    }
}

extension ReceiptEvent {
    /// A total ordering over events, so that folding is deterministic regardless of
    /// the order in which they were ingested.
    ///
    /// `effectiveAt` first, then the rail's own sequence number when it has one,
    /// then rail identifier, then `id`. The last two exist purely to make the
    /// ordering total — without them two same-instant events could swap places
    /// between runs and the verdict would flicker.
    static func isOrderedBefore(_ lhs: ReceiptEvent, _ rhs: ReceiptEvent) -> Bool {
        if lhs.effectiveAt != rhs.effectiveAt {
            return lhs.effectiveAt < rhs.effectiveAt
        }
        let left = lhs.railSequence ?? Int.max
        let right = rhs.railSequence ?? Int.max
        if left != right { return left < right }
        if lhs.rail.identifier != rhs.rail.identifier {
            return lhs.rail.identifier < rhs.rail.identifier
        }
        return lhs.id < rhs.id
    }
}
