import Foundation
@testable import EntitlementLedger

enum Clock {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    /// A fixed instant, so every test reads the same on every machine.
    static func at(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        guard let date = utc.date(from: components) else {
            preconditionFailure("Invalid fixture date \(year)-\(month)-\(day)")
        }
        return date
    }

    static let day: TimeInterval = 24 * 60 * 60
}

extension PaymentRail {
    static let stripe = PaymentRail.alternativeInApp(processor: "Stripe")
    static let web = PaymentRail.outOfApp(processor: "Paddle")
}

func purchase(
    _ id: String,
    rail: PaymentRail,
    product: String = "pro.annual",
    at date: Date,
    expires: Date? = nil,
    amount: Int? = nil,
    currency: String? = nil
) -> ReceiptEvent {
    ReceiptEvent(
        id: id, rail: rail, productID: product, kind: .purchase,
        effectiveAt: date, expiresAt: expires,
        amountMinorUnits: amount, currency: currency
    )
}

func event(
    _ id: String,
    _ kind: ReceiptEventKind,
    rail: PaymentRail,
    product: String = "pro.annual",
    at date: Date,
    expires: Date? = nil,
    amount: Int? = nil,
    currency: String? = nil
) -> ReceiptEvent {
    ReceiptEvent(
        id: id, rail: rail, productID: product, kind: kind,
        effectiveAt: date, expiresAt: expires,
        amountMinorUnits: amount, currency: currency
    )
}
