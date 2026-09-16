import Foundation

/// A customer tapping an out-of-app offer link.
public struct LinkTap: Hashable, Sendable, Identifiable {
    public let id: String
    public let productID: String
    public let occurredAt: Date

    public init(id: String, productID: String, occurredAt: Date) {
        self.id = id
        self.productID = productID
        self.occurredAt = occurredAt
    }
}

/// Whether a sale is inside the store services commission window.
public enum AttributionOutcome: Hashable, Sendable {
    /// Commissionable: a qualifying tap happened within the window.
    case attributed(tapID: String, elapsed: TimeInterval)
    /// Outside the window, or no tap at all.
    case unattributed

    public var isCommissionable: Bool {
        if case .attributed = self { return true }
        return false
    }
}

/// The seven-day window that decides whether an out-of-app sale owes Apple a
/// store services commission.
///
/// Apple: "Only sales made within 7 days of the link tap are subject to this
/// commission." That sentence turns a marketing link into a stateful attribution
/// problem: you have to know, for every out-of-app sale, whether some tap on some
/// device belonging to the same customer happened inside the previous week.
///
/// Source: [Payment options on the App Store in the EU](https://developer.apple.com/support/payment-options-on-the-app-store-in-the-eu)
public struct AttributionWindow: Hashable, Sendable {

    /// Seven days, in seconds. 604,800.
    public static let storeServices: TimeInterval = 7 * 24 * 60 * 60

    public let duration: TimeInterval

    public init(duration: TimeInterval = AttributionWindow.storeServices) {
        self.duration = duration
    }

    /// Whether a sale at `saleDate` falls inside the window opened by a tap at `tapDate`.
    ///
    /// **Boundary.** Apple does not say whether a sale at exactly seven days counts.
    /// This treats the boundary as inclusive, which is the conservative direction:
    /// being wrong here means paying a commission you might not have owed, rather
    /// than under-reporting to a party with audit rights.
    public func contains(saleAt saleDate: Date, tappedAt tapDate: Date) -> Bool {
        let elapsed = saleDate.timeIntervalSince(tapDate)
        return elapsed >= 0 && elapsed <= duration
    }
}

/// Records link taps and decides which out-of-app sales they earned.
public struct AttributionLedger: Sendable {

    public let window: AttributionWindow
    private var taps: [String: LinkTap]

    public init(window: AttributionWindow = AttributionWindow(), taps: [LinkTap] = []) {
        self.window = window
        self.taps = [:]
        record(taps)
    }

    /// Records a tap. Idempotent on `id`, because analytics pipelines replay.
    @discardableResult
    public mutating func record(_ tap: LinkTap) -> Bool {
        guard taps[tap.id] == nil else { return false }
        taps[tap.id] = tap
        return true
    }

    @discardableResult
    public mutating func record(_ newTaps: [LinkTap]) -> Int {
        newTaps.reduce(into: 0) { count, tap in
            if record(tap) { count += 1 }
        }
    }

    public var allTaps: [LinkTap] {
        taps.values.sorted { lhs, rhs in
            lhs.occurredAt == rhs.occurredAt ? lhs.id < rhs.id : lhs.occurredAt < rhs.occurredAt
        }
    }

    /// Attributes a sale to the most recent qualifying tap for the same product.
    ///
    /// Most recent, not first: if a customer tapped twice, the later tap is the one
    /// that was in front of them when they paid.
    public func attribute(saleOf productID: String, at saleDate: Date) -> AttributionOutcome {
        let qualifying = taps.values
            .filter { $0.productID == productID && window.contains(saleAt: saleDate, tappedAt: $0.occurredAt) }
            .sorted { lhs, rhs in
                lhs.occurredAt == rhs.occurredAt ? lhs.id < rhs.id : lhs.occurredAt < rhs.occurredAt
            }
        guard let tap = qualifying.last else { return .unattributed }
        return .attributed(tapID: tap.id, elapsed: saleDate.timeIntervalSince(tap.occurredAt))
    }
}
