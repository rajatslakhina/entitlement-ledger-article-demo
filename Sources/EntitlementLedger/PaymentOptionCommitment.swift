import Foundation

/// The payment options an app offers on EU storefronts.
public struct PaymentOptionSelection: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let appleIAP = PaymentOptionSelection(rawValue: 1 << 0)
    public static let alternativeInApp = PaymentOptionSelection(rawValue: 1 << 1)
    /// Out-of-app offers reached through an actionable link — one that can be
    /// tapped, clicked or scanned.
    public static let outOfAppActionableLink = PaymentOptionSelection(rawValue: 1 << 2)

    public var isEmpty: Bool { rawValue == 0 }

    public var labels: [String] {
        var out: [String] = []
        if contains(.appleIAP) { out.append("Apple In-App Purchase") }
        if contains(.alternativeInApp) { out.append("Alternative payment processing in-app") }
        if contains(.outOfAppActionableLink) { out.append("Out-of-app offers (actionable link)") }
        return out
    }
}

/// Whether a proposed change to the payment mix is allowed today.
public enum CommitmentVerdict: Hashable, Sendable {
    case noChange
    case allowed
    case locked(until: Date, daysRemaining: Int)

    public var isAllowed: Bool {
        switch self {
        case .noChange, .allowed: return true
        case .locked: return false
        }
    }
}

/// Why a proposed selection cannot be shipped at all.
public enum SelectionDefect: Hashable, Sendable, CustomStringConvertible {
    /// You have to sell somehow.
    case empty
    /// Guideline 3.1.3(b): an app in the EU offering a multiplatform service must
    /// offer Apple In-App Purchase and/or alternative payment processing within the
    /// app. Out-of-app offers alone are not enough.
    case multiplatformServiceNeedsInAppOption

    public var description: String {
        switch self {
        case .empty:
            return "A payment selection must contain at least one option."
        case .multiplatformServiceNeedsInAppOption:
            return "Guideline 3.1.3(b): a multiplatform service must offer Apple In-App Purchase and/or alternative in-app payment processing."
        }
    }
}

/// The 12-month lock on your choice of payment options.
///
/// Apple's wording: "once you select a payment option or combination — Apple
/// In-App Purchase, alternative payment processing within the app, and/or out-of-app
/// offers with actionable links — you must maintain that choice across all EU
/// storefronts for 12 months."
///
/// This type exists so that the lock is a thing in the codebase rather than a line
/// in a slide deck. A decision you cannot reverse for a year is an architecture
/// decision, and it should fail a check, not a retrospective.
///
/// **Reading note.** Apple says "maintain that choice"; it does not say whether
/// *adding* an option counts as changing it. This type takes the conservative
/// reading — any delta is a change — because the cost of being wrong is a
/// compliance conversation, not a refactor. If your legal team reads it differently,
/// change `evaluate(changeTo:on:)` and write down who decided.
///
/// Source: [Payment options on the App Store in the EU](https://developer.apple.com/support/payment-options-on-the-app-store-in-the-eu)
public struct PaymentOptionCommitment: Hashable, Sendable {

    /// The lock, in months, from Apple's terms.
    public static let lockMonths = 12

    public let selection: PaymentOptionSelection
    public let committedOn: Date

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    public init(selection: PaymentOptionSelection, committedOn: Date) {
        self.selection = selection
        self.committedOn = committedOn
    }

    /// The instant the lock lifts.
    ///
    /// Falls back to a 365-day interval only if calendar arithmetic fails, which it
    /// does not for the Gregorian calendar — the fallback is here so the property is
    /// non-optional at the call site.
    public var lockExpires: Date {
        Self.calendar.date(byAdding: .month, value: Self.lockMonths, to: committedOn)
            ?? committedOn.addingTimeInterval(365 * 24 * 60 * 60)
    }

    /// Checks a selection against the rules that apply before the lock even matters.
    public static func defects(
        in selection: PaymentOptionSelection,
        isMultiplatformService: Bool
    ) -> [SelectionDefect] {
        var defects: [SelectionDefect] = []
        if selection.isEmpty { defects.append(.empty) }
        if isMultiplatformService,
           !selection.contains(.appleIAP),
           !selection.contains(.alternativeInApp) {
            defects.append(.multiplatformServiceNeedsInAppOption)
        }
        return defects
    }

    /// Can we move to `proposed` on `date`?
    public func evaluate(changeTo proposed: PaymentOptionSelection, on date: Date) -> CommitmentVerdict {
        guard proposed != selection else { return .noChange }
        let expiry = lockExpires
        guard date < expiry else { return .allowed }
        let days = Self.calendar.dateComponents([.day], from: date, to: expiry).day ?? 0
        return .locked(until: expiry, daysRemaining: max(0, days))
    }
}
