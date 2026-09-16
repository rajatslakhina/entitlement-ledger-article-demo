import XCTest
@testable import EntitlementLedger

final class PaymentOptionCommitmentTests: XCTestCase {

    private let launch = Clock.at(2026, 10, 1)

    func testLockRunsTwelveCalendarMonths() {
        let commitment = PaymentOptionCommitment(
            selection: [.appleIAP, .alternativeInApp],
            committedOn: launch
        )
        XCTAssertEqual(commitment.lockExpires, Clock.at(2027, 10, 1))
    }

    func testChangingTheMixInsideTheLockIsRefused() {
        let commitment = PaymentOptionCommitment(
            selection: [.appleIAP, .alternativeInApp],
            committedOn: launch
        )
        let verdict = commitment.evaluate(changeTo: [.appleIAP], on: Clock.at(2027, 3, 1))

        guard case .locked(let until, let days) = verdict else {
            return XCTFail("Expected the 12-month lock to bite, got \(verdict)")
        }
        XCTAssertEqual(until, Clock.at(2027, 10, 1))
        XCTAssertEqual(days, 214)
        XCTAssertFalse(verdict.isAllowed)
    }

    /// Conservative reading: adding an option is still a change to "that choice".
    func testAddingAnOptionInsideTheLockIsAlsoRefused() {
        let commitment = PaymentOptionCommitment(selection: [.appleIAP], committedOn: launch)
        let verdict = commitment.evaluate(
            changeTo: [.appleIAP, .outOfAppActionableLink],
            on: Clock.at(2027, 1, 1)
        )
        XCTAssertFalse(verdict.isAllowed)
    }

    func testReCommittingTheSameMixIsNotAChange() {
        let commitment = PaymentOptionCommitment(selection: [.appleIAP], committedOn: launch)
        XCTAssertEqual(
            commitment.evaluate(changeTo: [.appleIAP], on: Clock.at(2027, 1, 1)),
            .noChange
        )
    }

    func testChangeIsAllowedOnceTheLockLifts() {
        let commitment = PaymentOptionCommitment(selection: [.appleIAP], committedOn: launch)
        XCTAssertEqual(
            commitment.evaluate(changeTo: [.appleIAP, .alternativeInApp], on: Clock.at(2027, 10, 1)),
            .allowed
        )
    }

    func testEmptySelectionIsDefective() {
        let defects = PaymentOptionCommitment.defects(in: [], isMultiplatformService: false)
        XCTAssertEqual(defects, [.empty])
    }

    /// Guideline 3.1.3(b): out-of-app offers alone are not a payment option for a
    /// multiplatform service.
    func testMultiplatformServiceRejectsOutOfAppOnly() {
        let defects = PaymentOptionCommitment.defects(
            in: [.outOfAppActionableLink],
            isMultiplatformService: true
        )
        XCTAssertEqual(defects, [.multiplatformServiceNeedsInAppOption])
    }

    func testMultiplatformServiceAcceptsAlternativeInAppWithoutIAP() {
        let defects = PaymentOptionCommitment.defects(
            in: [.alternativeInApp, .outOfAppActionableLink],
            isMultiplatformService: true
        )
        XCTAssertTrue(defects.isEmpty)
    }

    func testOutOfAppOnlyIsFineForANonMultiplatformApp() {
        let defects = PaymentOptionCommitment.defects(
            in: [.outOfAppActionableLink],
            isMultiplatformService: false
        )
        XCTAssertTrue(defects.isEmpty)
    }
}

final class AttributionTests: XCTestCase {

    private let tapDate = Clock.at(2026, 10, 1, 12)

    func testWindowIsSevenDays() {
        XCTAssertEqual(AttributionWindow.storeServices, 604_800)
    }

    func testSaleJustInsideTheWindowIsCommissionable() {
        var ledger = AttributionLedger()
        ledger.record(LinkTap(id: "tap-1", productID: "pro.annual", occurredAt: tapDate))

        let outcome = ledger.attribute(
            saleOf: "pro.annual",
            at: tapDate.addingTimeInterval(AttributionWindow.storeServices - 1)
        )
        XCTAssertTrue(outcome.isCommissionable)
    }

    /// The boundary is inclusive by choice — see `AttributionWindow.contains`.
    func testSaleAtExactlySevenDaysIsCommissionable() {
        var ledger = AttributionLedger()
        ledger.record(LinkTap(id: "tap-1", productID: "pro.annual", occurredAt: tapDate))

        let outcome = ledger.attribute(
            saleOf: "pro.annual",
            at: tapDate.addingTimeInterval(AttributionWindow.storeServices)
        )
        XCTAssertTrue(outcome.isCommissionable)
    }

    func testSaleOneSecondPastTheWindowIsNotCommissionable() {
        var ledger = AttributionLedger()
        ledger.record(LinkTap(id: "tap-1", productID: "pro.annual", occurredAt: tapDate))

        let outcome = ledger.attribute(
            saleOf: "pro.annual",
            at: tapDate.addingTimeInterval(AttributionWindow.storeServices + 1)
        )
        XCTAssertEqual(outcome, .unattributed)
    }

    func testSaleBeforeTheTapIsNotAttributed() {
        var ledger = AttributionLedger()
        ledger.record(LinkTap(id: "tap-1", productID: "pro.annual", occurredAt: tapDate))

        let outcome = ledger.attribute(saleOf: "pro.annual", at: tapDate.addingTimeInterval(-60))
        XCTAssertEqual(outcome, .unattributed)
    }

    func testMostRecentQualifyingTapWins() {
        var ledger = AttributionLedger()
        ledger.record([
            LinkTap(id: "tap-old", productID: "pro.annual", occurredAt: tapDate),
            LinkTap(id: "tap-new", productID: "pro.annual", occurredAt: tapDate.addingTimeInterval(3 * Clock.day))
        ])

        let outcome = ledger.attribute(saleOf: "pro.annual", at: tapDate.addingTimeInterval(4 * Clock.day))
        guard case .attributed(let tapID, let elapsed) = outcome else {
            return XCTFail("Expected attribution, got \(outcome)")
        }
        XCTAssertEqual(tapID, "tap-new")
        XCTAssertEqual(elapsed, Clock.day, accuracy: 0.5)
    }

    /// An expired tap must not be revived by a newer tap on a different product.
    func testTapsAreScopedToTheirProduct() {
        var ledger = AttributionLedger()
        ledger.record([
            LinkTap(id: "tap-pro", productID: "pro.annual", occurredAt: tapDate),
            LinkTap(id: "tap-coach", productID: "coach.monthly",
                    occurredAt: tapDate.addingTimeInterval(9 * Clock.day))
        ])

        let outcome = ledger.attribute(saleOf: "pro.annual", at: tapDate.addingTimeInterval(10 * Clock.day))
        XCTAssertEqual(outcome, .unattributed)
    }

    func testTapsAreIdempotent() {
        var ledger = AttributionLedger()
        let tap = LinkTap(id: "tap-1", productID: "pro.annual", occurredAt: tapDate)
        XCTAssertTrue(ledger.record(tap))
        XCTAssertFalse(ledger.record(tap))
        XCTAssertEqual(ledger.allTaps.count, 1)
    }
}

final class TransactionReportTests: XCTestCase {

    private let september = ReportingPeriod(year: 2026, month: 9)

    private let october = ReportingPeriod(year: 2026, month: 10)

    private func octoberLedger() -> EntitlementLedger {
        EntitlementLedger(policy: .mostGenerous, events: [
            purchase("apple-1", rail: .appleIAP, at: Clock.at(2026, 10, 3), amount: 4999, currency: "EUR"),
            purchase("psp-1", rail: .stripe, at: Clock.at(2026, 10, 4), amount: 3999, currency: "EUR"),
            event("psp-2", .renewal, rail: .stripe, at: Clock.at(2026, 10, 9), amount: 3999, currency: "EUR"),
            event("psp-3", .refund, rail: .stripe, at: Clock.at(2026, 10, 11), amount: -3999, currency: "EUR"),
            event("psp-4", .correction, rail: .stripe, at: Clock.at(2026, 10, 12), amount: 100, currency: "EUR"),
            event("psp-5", .abandoned, rail: .web, at: Clock.at(2026, 10, 14), amount: 0, currency: "EUR"),
            // Next month — must not appear in October's report.
            purchase("psp-6", rail: .stripe, at: Clock.at(2026, 11, 1), amount: 3999, currency: "EUR")
        ])
    }

    func testFilingDeadlineIsFifteenDaysAfterTheMonthEnds() {
        XCTAssertEqual(september.end, Clock.at(2026, 10, 1))
        XCTAssertEqual(september.filingDeadline, Clock.at(2026, 10, 16))
        XCTAssertEqual(september.lastFullDayToFile, Clock.at(2026, 10, 15))
    }

    func testFilingDeadlineHandlesTheYearBoundary() {
        let december = ReportingPeriod(year: 2026, month: 12)
        XCTAssertEqual(december.end, Clock.at(2027, 1, 1))
        XCTAssertEqual(december.filingDeadline, Clock.at(2027, 1, 16))
    }

    func testOnTimeAndLateFiling() {
        XCTAssertTrue(september.contains(Clock.at(2026, 9, 30, 23)))
        XCTAssertFalse(september.contains(Clock.at(2026, 10, 1)))

        let report = TransactionReport(period: september, ledger: EntitlementLedger())
        XCTAssertTrue(report.isOnTime(filedAt: Clock.at(2026, 10, 15, 23)))
        XCTAssertFalse(report.isOnTime(filedAt: Clock.at(2026, 10, 16)))
    }

    func testReportExcludesAppleInAppPurchase() {
        let report = TransactionReport(period: october, ledger: octoberLedger())
        XCTAssertFalse(report.rows.contains { $0.rail == .appleIAP })
        XCTAssertFalse(report.rows.contains { $0.eventID == "apple-1" })
    }

    /// The line teams miss: a transaction that did not result in a purchase is
    /// still reportable.
    func testReportIncludesAbandonedTransactions() {
        let report = TransactionReport(period: october, ledger: octoberLedger())
        XCTAssertEqual(report.countsByKind[.abandoned], 1)
        XCTAssertTrue(report.rows.contains { $0.eventID == "psp-5" })
    }

    func testReportCoversEveryReportableKind() {
        let report = TransactionReport(period: october, ledger: octoberLedger())
        XCTAssertEqual(report.rows.count, 5)
        XCTAssertEqual(report.countsByKind[.purchase], 1)
        XCTAssertEqual(report.countsByKind[.renewal], 1)
        XCTAssertEqual(report.countsByKind[.refund], 1)
        XCTAssertEqual(report.countsByKind[.correction], 1)
        XCTAssertEqual(report.countsByKind[.abandoned], 1)
    }

    func testReportRespectsTheMonthBoundary() {
        let report = TransactionReport(period: october, ledger: octoberLedger())
        XCTAssertFalse(report.rows.contains { $0.eventID == "psp-6" })
    }

    func testGrossCountsOnlyMoneyIn() {
        let report = TransactionReport(period: october, ledger: octoberLedger())
        XCTAssertEqual(report.grossMinorUnits, 3999 + 3999)
    }
}

final class CommissionScheduleTests: XCTestCase {

    func testPublishedEURates() {
        XCTAssertEqual(CommissionSchedule.rate(for: .appleIAP, tier: .standard), 0.26, accuracy: 0.0001)
        XCTAssertEqual(CommissionSchedule.rate(for: .appleIAP, tier: .reduced), 0.15, accuracy: 0.0001)
        XCTAssertEqual(CommissionSchedule.rate(for: .stripe, tier: .standard), 0.20, accuracy: 0.0001)
        XCTAssertEqual(CommissionSchedule.rate(for: .stripe, tier: .reduced), 0.10, accuracy: 0.0001)
        XCTAssertEqual(CommissionSchedule.rate(for: .web, tier: .standard), 0.15, accuracy: 0.0001)
        XCTAssertEqual(CommissionSchedule.rate(for: .web, tier: .reduced), 0.10, accuracy: 0.0001)
    }

    func testAlternativeInAppIsCheaperThanIAPAtBothTiers() {
        XCTAssertLessThan(
            CommissionSchedule.rate(for: .stripe, tier: .standard),
            CommissionSchedule.rate(for: .appleIAP, tier: .standard)
        )
        XCTAssertLessThan(
            CommissionSchedule.rate(for: .stripe, tier: .reduced),
            CommissionSchedule.rate(for: .appleIAP, tier: .reduced)
        )
    }

    func testOnlyAppleInAppPurchaseIsVisibleToApple() {
        XCTAssertTrue(PaymentRail.appleIAP.isVisibleToApple)
        XCTAssertFalse(PaymentRail.stripe.isVisibleToApple)
        XCTAssertFalse(PaymentRail.web.isVisibleToApple)
        XCTAssertFalse(PaymentRail.appleIAP.isReportable)
        XCTAssertTrue(PaymentRail.stripe.isReportable)
    }
}
