import Foundation

/// A channel through which money for a digital good can reach you.
///
/// Under the unified EU business terms that take effect on 1 October 2026, an app on
/// an EU storefront may offer Apple In-App Purchase, alternative payment processing
/// inside the app, and out-of-app offers — at the same time, in the same app.
/// Each of those is a separate rail with its own receipts, its own refund semantics
/// and its own idea of what the customer owns.
///
/// Source: [Payment options on the App Store in the EU](https://developer.apple.com/support/payment-options-on-the-app-store-in-the-eu)
public enum PaymentRail: Hashable, Sendable, Codable {

    /// Apple In-App Purchase. Receipts arrive through StoreKit 2.
    case appleIAP

    /// An alternative payment processor running inside the app, reached through
    /// `ExternalPurchaseCustomLink`. Receipts arrive from the PSP, usually by webhook.
    case alternativeInApp(processor: String)

    /// An out-of-app offer: the customer leaves for a website, another app or an
    /// alternative marketplace. Receipts arrive from whatever processed the sale there.
    case outOfApp(processor: String)

    /// Whether Apple's own systems can see and service this rail's transactions.
    ///
    /// Apple states plainly that Report a Problem and Family Sharing "will also not
    /// reflect these transactions", and that purchase history and subscription
    /// management "will only reflect transactions made using Apple In-App Purchase".
    /// That single sentence is why `Transaction.currentEntitlements` stops being an
    /// answer and starts being one input among several.
    public var isVisibleToApple: Bool {
        switch self {
        case .appleIAP: return true
        case .alternativeInApp, .outOfApp: return false
        }
    }

    /// Whether this rail's transactions must appear in the monthly report you send Apple.
    ///
    /// Apple already has its own In-App Purchase records, so only the alternative
    /// rails are reportable.
    public var isReportable: Bool { !isVisibleToApple }

    /// A stable identifier used for deterministic ordering and dictionary keys.
    public var identifier: String {
        switch self {
        case .appleIAP: return "apple-iap"
        case .alternativeInApp(let processor): return "alt-in-app:\(processor)"
        case .outOfApp(let processor): return "out-of-app:\(processor)"
        }
    }
}

extension PaymentRail: CustomStringConvertible {
    public var description: String {
        switch self {
        case .appleIAP: return "Apple In-App Purchase"
        case .alternativeInApp(let processor): return "\(processor) (in-app)"
        case .outOfApp(let processor): return "\(processor) (out-of-app)"
        }
    }
}
