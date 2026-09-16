import Foundation

/// An open grant of access, attributed to exactly one rail.
public struct Grant: Hashable, Sendable {
    public let productID: String
    public let rail: PaymentRail
    public let grantedAt: Date
    /// `nil` means the grant does not expire.
    public let expiresAt: Date?
    /// The event that opened this grant. Kept so that support can answer
    /// "why does this person have access" with a receipt id rather than a shrug.
    public let sourceEventID: String

    public init(
        productID: String,
        rail: PaymentRail,
        grantedAt: Date,
        expiresAt: Date?,
        sourceEventID: String
    ) {
        self.productID = productID
        self.rail = rail
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.sourceEventID = sourceEventID
    }

    /// Whether the grant is open at `date`, ignoring grace.
    public func isActive(at date: Date) -> Bool {
        guard date >= grantedAt else { return false }
        guard let expiresAt else { return true }
        return date < expiresAt
    }
}

/// Why access was refused.
public enum DenialReason: Hashable, Sendable {
    /// No rail ever opened a grant for this product.
    case noGrant
    /// A grant existed and its period ended; grace, if any, has run out.
    case expired(at: Date)
    /// The rail that opened the grant refunded it.
    case refunded(rail: PaymentRail, at: Date)
    /// The rail that opened the grant withdrew it without a refund.
    case revoked(rail: PaymentRail, at: Date)
}

/// What one rail believes about one product at one instant.
///
/// Three states, not two: a rail can have an open grant, have nothing to say, or
/// have explicitly taken access away. Collapsing the last two loses the difference
/// between "we never sold them this" and "we refunded them", which is the difference
/// between two very different support conversations.
public enum RailState: Hashable, Sendable {
    /// The rail has an open grant. It may still be expired — ask the grant.
    case open(Grant)
    /// The rail has no record that opens access.
    case silent
    /// The rail opened access and then took it away.
    case closed(DenialReason)

    public var grant: Grant? {
        if case .open(let grant) = self { return grant }
        return nil
    }

    public var closure: DenialReason? {
        if case .closed(let reason) = self { return reason }
        return nil
    }
}

/// The ledger's answer to "does this person own this right now".
public enum EntitlementVerdict: Hashable, Sendable {
    /// An open grant.
    case entitled(Grant)
    /// The grant's period has ended but the configured grace window has not.
    /// Ship access; chase the renewal.
    case grace(Grant, until: Date)
    /// No access.
    case notEntitled(DenialReason)

    public var allowsAccess: Bool {
        switch self {
        case .entitled, .grace: return true
        case .notEntitled: return false
        }
    }

    /// The rail responsible for this verdict, when there is one.
    public var rail: PaymentRail? {
        switch self {
        case .entitled(let grant): return grant.rail
        case .grace(let grant, _): return grant.rail
        case .notEntitled: return nil
        }
    }
}

/// How to resolve two rails holding open grants for the same product at the same time.
public enum ConflictRule: Hashable, Sendable {
    /// Keep the grant that runs longest; a non-expiring grant always wins.
    ///
    /// The right default. If the two rails disagree, the customer paid at least once
    /// and the cheapest possible mistake is giving them what they paid for.
    case mostGenerous

    /// Keep the grant that runs shortest.
    ///
    /// Here so the difference is testable, and for the rare product where over-granting
    /// costs more than a support ticket — a metered licence you resell, say.
    case strictest

    /// Prefer rails in the given order; anything unlisted falls back to `mostGenerous`.
    ///
    /// Use it when one rail is genuinely more trustworthy — for example while a new
    /// PSP integration is still being trusted in production.
    case railPriority([PaymentRail])
}

/// The decisions a lead has to make before anyone writes the PSP integration:
/// who wins when the rails disagree, and how long you keep serving a customer
/// whose renewal you cannot currently see.
public struct ReconciliationPolicy: Hashable, Sendable {

    public let conflictRule: ConflictRule

    /// How long after a grant's expiry access is still served.
    ///
    /// This is not generosity, it is a availability decision. An alternative rail's
    /// renewal webhook can be late for reasons that have nothing to do with the
    /// customer, and Apple will not be answering their support email.
    public let gracePeriod: TimeInterval

    public init(conflictRule: ConflictRule = .mostGenerous, gracePeriod: TimeInterval = 0) {
        self.conflictRule = conflictRule
        self.gracePeriod = max(0, gracePeriod)
    }

    /// Longest expiry wins, no grace. Safe for one-time purchases.
    public static let mostGenerous = ReconciliationPolicy(conflictRule: .mostGenerous, gracePeriod: 0)

    /// What most subscription apps should actually ship: longest expiry wins, and a
    /// 72-hour grace window so a late webhook from an alternative processor does not
    /// lock out a paying customer over a weekend.
    public static let subscription = ReconciliationPolicy(
        conflictRule: .mostGenerous,
        gracePeriod: 72 * 60 * 60
    )
}
