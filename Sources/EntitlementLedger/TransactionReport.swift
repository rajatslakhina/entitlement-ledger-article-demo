import Foundation

/// A calendar month, in UTC.
public struct ReportingPeriod: Hashable, Sendable, Comparable {
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) {
        self.year = year
        self.month = min(12, max(1, month))
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    /// First instant of the month.
    public var start: Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        return Self.calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    /// First instant of the following month — the exclusive upper bound.
    public var end: Date {
        Self.calendar.date(byAdding: .month, value: 1, to: start) ?? start
    }

    /// The instant the 15-day filing window closes.
    ///
    /// Apple: the report "will need to be provided monthly within 15 days following
    /// the end of the calendar month." The month ends at `end`; fifteen days later
    /// the window shuts. For September 2026 that is 16 October 00:00 UTC, which
    /// means the last full day to file is 15 October.
    public var filingDeadline: Date {
        Self.calendar.date(byAdding: .day, value: 15, to: end) ?? end
    }

    /// The last whole day on which the report can be filed.
    public var lastFullDayToFile: Date {
        Self.calendar.date(byAdding: .day, value: -1, to: filingDeadline) ?? filingDeadline
    }

    public func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }

    public static func < (lhs: ReportingPeriod, rhs: ReportingPeriod) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }
}

/// One line of the monthly report to Apple.
public struct ReportRow: Hashable, Sendable {
    public let eventID: String
    public let rail: PaymentRail
    public let productID: String
    public let kind: ReceiptEventKind
    public let occurredAt: Date
    public let amountMinorUnits: Int?
    public let currency: String?
}

/// The monthly transaction report for alternative payments.
///
/// Apple: "You're also required to track and send Apple a report of all alternative
/// payment transactions for applicable commission fee calculation and collection
/// purposes. Required reporting includes refunds, corrections, renewals, one-time
/// purchases, and transactions that didn't result in a purchase."
///
/// Two things in that sentence cost teams money. The first is that abandoned
/// transactions are reportable — nothing happened, so nothing got logged, so the
/// report is wrong. The second is that Apple holds audit rights over it.
///
/// Source: [Payment options on the App Store in the EU](https://developer.apple.com/support/payment-options-on-the-app-store-in-the-eu)
public struct TransactionReport: Sendable {

    public let period: ReportingPeriod
    public let rows: [ReportRow]

    /// Builds the report for `period` from a ledger.
    ///
    /// Apple In-App Purchase events are excluded: Apple already has them.
    public init(period: ReportingPeriod, ledger: EntitlementLedger) {
        self.period = period
        self.rows = ledger.allEvents
            .filter { $0.rail.isReportable && period.contains($0.effectiveAt) }
            .map {
                ReportRow(
                    eventID: $0.id,
                    rail: $0.rail,
                    productID: $0.productID,
                    kind: $0.kind,
                    occurredAt: $0.effectiveAt,
                    amountMinorUnits: $0.amountMinorUnits,
                    currency: $0.currency
                )
            }
    }

    public var filingDeadline: Date { period.filingDeadline }

    /// Row counts by kind — the shape of the report, for a dashboard or a sanity check.
    public var countsByKind: [ReceiptEventKind: Int] {
        rows.reduce(into: [:]) { counts, row in
            counts[row.kind, default: 0] += 1
        }
    }

    /// Gross minor units for rows that moved money towards you.
    public var grossMinorUnits: Int {
        rows
            .filter { $0.kind == .purchase || $0.kind == .renewal }
            .compactMap(\.amountMinorUnits)
            .reduce(0, +)
    }

    /// Whether the report was filed in time.
    public func isOnTime(filedAt: Date) -> Bool {
        filedAt < filingDeadline
    }
}

/// Commission tiers under the unified EU terms.
public enum CommissionTier: Hashable, Sendable {
    /// The headline rate.
    case standard
    /// App Store Small Business Program, Mini Apps Partner Program or Video Partner
    /// Program participants, and auto-renewable subscriptions after their first year.
    case reduced
}

/// The published EU commission rates that take effect on 1 October 2026.
///
/// Rates are expressed as a fraction of the price paid by the customer.
///
/// Source: [Payment options on the App Store in the EU](https://developer.apple.com/support/payment-options-on-the-app-store-in-the-eu)
public enum CommissionSchedule {

    /// Apple In-App Purchase: 26% standard, 15% reduced.
    /// Alternative payment processing within the app: 20% standard, 10% reduced.
    /// Out-of-app offers (store services commission): 15% standard, 10% reduced,
    /// and only on sales made within seven days of the link tap.
    public static func rate(for rail: PaymentRail, tier: CommissionTier) -> Double {
        switch (rail, tier) {
        case (.appleIAP, .standard): return 0.26
        case (.appleIAP, .reduced): return 0.15
        case (.alternativeInApp, .standard): return 0.20
        case (.alternativeInApp, .reduced): return 0.10
        case (.outOfApp, .standard): return 0.15
        case (.outOfApp, .reduced): return 0.10
        }
    }
}
