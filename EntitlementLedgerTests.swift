import XCTest
@testable import EntitlementLedger

final class IngestionTests: XCTestCase {

    func testDuplicateEventIDsAreIgnored() {
        var ledger = EntitlementLedger(policy: .mostGenerous)
        let receipt = purchase("evt-1", rail: .stripe, at: Clock.at(2026, 10, 1))

        XCTAssertTrue(ledger.ingest(receipt))
        XCTAssertFalse(ledger.ingest(receipt), "A redelivered webhook must be a no-op.")
        XCTAssertEqual(ledger.allEvents.count, 1)
    }

    func testIngestBatchReportsOnlyNewEvents() {
        var ledger = EntitlementLedger(policy: .mostGenerous)
        let first = purchase("evt-1", rail: .stripe, at: Clock.at(2026, 10, 1))
        let second = purchase("evt-2", rail: .appleIAP, at: Clock.at(2026, 10, 2))

        XCTAssertEqual(ledger.ingest([first, second]), 2)
        XCTAssertEqual(ledger.ingest([first, second]), 0)
    }

    func testVerdictIsIndependentOfIngestionOrder() {
        let start = Clock.at(2026, 10, 1)
        let events = [
            purchase("p1", rail: .stripe, at: start, expires: start.addingTimeInterval(30 * Clock.day)),
            event("r1", .refund, rail: .stripe, at: start.addingTimeInterval(5 * Clock.day)),
            purchase("p2", rail: .appleIAP, at: start.addingTimeInterval(2 * Clock.day),
                     expires: start.addingTimeInterval(40 * Clock.day)),
            event("c1", .correction, rail: .stripe, at: start.addingTimeInterval(6 * Clock.day))
        ]
        let asOf = start.addingTimeInterval(10 * Clock.day)

        let forward = EntitlementLedger(policy: .mostGenerous, events: events)
            .verdict(for: "pro.annual", at: asOf)
        let backward = EntitlementLedger(policy: .mostGenerous, events: events.reversed())
            .verdict(for: "pro.annual", at: asOf)
        let shuffled = EntitlementLedger(policy: .mostGenerous, events: [events[3], events[1], events[0], events[2]])
            .verdict(for: "pro.annual", at: asOf)

        XCTAssertEqual(forward, backward)
        XCTAssertEqual(forward, shuffled)
        XCTAssertEqual(forward.rail, .appleIAP)
    }

    func testEmptyLedgerIsNotEntitled() {
        let ledger = EntitlementLedger(policy: .mostGenerous)
        XCTAssertEqual(
            ledger.verdict(for: "pro.annual", at: Clock.at(2026, 10, 1)),
            .notEntitled(.noGrant)
        )
    }
}

final class RailIsolationTests: XCTestCase {

    /// The bug this whole package exists to stop: a chargeback from the payment
    /// processor taking away a subscription the customer bought through Apple.
    func testRefundOnOneRailDoesNotRevokeAnotherRailsGrant() {
        let start = Clock.at(2026, 10, 1)
        let expiry = start.addingTimeInterval(365 * Clock.day)
        var ledger = EntitlementLedger(policy: .mostGenerous)

        ledger.ingest(purchase("apple-1", rail: .appleIAP, at: start, expires: expiry))
        ledger.ingest(purchase("psp-1", rail: .stripe, at: start, expires: expiry))
        ledger.ingest(event("psp-refund", .refund, rail: .stripe, at: start.addingTimeInterval(Clock.day)))

        let verdict = ledger.verdict(for: "pro.annual", at: start.addingTimeInterval(2 * Clock.day))
        XCTAssertTrue(verdict.allowsAccess)
        XCTAssertEqual(verdict.rail, .appleIAP)
    }

    func testRefundClosesItsOwnRailsGrant() {
        let start = Clock.at(2026, 10, 1)
        var ledger = EntitlementLedger(policy: .mostGenerous)
        ledger.ingest(purchase("psp-1", rail: .stripe, at: start,
                               expires: start.addingTimeInterval(365 * Clock.day)))
        ledger.ingest(event("psp-refund", .refund, rail: .stripe, at: start.addingTimeInterval(Clock.day)))

        let verdict = ledger.verdict(for: "pro.annual", at: start.addingTimeInterval(2 * Clock.day))
        XCTAssertEqual(verdict, .notEntitled(.refunded(rail: .stripe, at: start.addingTimeInterval(Clock.day))))
    }

    func testRevocationIsReportedSeparatelyFromRefund() {
        let start = Clock.at(2026, 10, 1)
        var ledger = EntitlementLedger(policy: .mostGenerous)
        ledger.ingest(purchase("psp-1", rail: .stripe, at: start,
                               expires: start.addingTimeInterval(365 * Clock.day)))
        ledger.ingest(event("psp-chargeback", .revocation, rail: .stripe,
                            at: start.addingTimeInterval(Clock.day)))

        let verdict = ledger.verdict(for: "pro.annual", at: start.addingTimeInterval(2 * Clock.day))
        XCTAssertEqual(verdict, .notEntitled(.revoked(rail: .stripe, at: start.addingTimeInterval(Clock.day))))
    }

    /// A refund that arrives before the purchase it refunds must not strand the grant.
    func testRefundArrivingBeforeAnUnrelatedLaterPurchaseDoesNotBlockIt() {
        let start = Clock.at(2026, 10, 1)
        var ledger = EntitlementLedger(policy: .mostGenerous)
        ledger.ingest(purchase("psp-1", rail: .stripe, at: start, expires: start.addingTimeInterval(30 * Clock.day)))
        ledger.ingest(event("psp-refund", .refund, rail: .stripe, at: start.addingTimeInterval(Clock.day)))
        // The customer comes back a week later and buys again on the same rail.
        ledger.ingest(purchase("psp-2", rail: .stripe, at: start.addingTimeInterval(7 * Clock.day),
                               expires: start.addingTimeInterval(37 * Clock.day)))

        let verdict = ledger.verdict(for: "pro.annual", at: start.addingTimeInterval(8 * Clock.day))
        XCTAssertTrue(verdict.allowsAccess)
        XCTAssertEqual(verdict.rail, .stripe)
    }
}

final class EventKindTests: XCTestCase {

    func testAbandonedNeverGrantsAccess() {
        let start = Clock.at(2026, 10, 1)
        var ledger = EntitlementLedger(policy: .mostGenerous)
        ledger.ingest(event("psp-abandoned", .abandoned, rail: .stripe, at: start,
                            expires: start.addingTimeInterval(365 * Clock.day)))

        XCTAssertEqual(
            ledger.verdict(for: "pro.annual", at: start.addingTimeInterval(Clock.day)),
            .notEntitled(.noGrant)
        )
    }

    func testCorrectionIsEntitlementNeutral() {
        let start = Clock.at(2026, 10, 1)
        let expiry = start.addingTimeInterval(30 * Clock.day)
        var ledger = EntitlementLedger(policy: .mostGenerous)
        ledger.ingest(purchase("psp-1", rail: .stripe, at: start, expires: expiry))
        let before = ledger.verdict(for: "pro.annual", at: start.addingTimeInterval(Clock.day))

        ledger.ingest(event("psp-corr", .correction, rail: .stripe, at: start.addingTimeInterval(2 * 3600)))
        let after = ledger.verdict(for: "pro.annual", at: start.addingTimeInterval(Clock.day))

        XCTAssertEqual(before, after)
        XCTAssertTrue(after.allowsAccess)
    }

    func testRenewalExtendsAccess() {
        let start = Clock.at(2026, 10, 1)
        var ledger = EntitlementLedger(policy: .mostGenerous)
        ledger.ingest(purchase("psp-1", rail: .stripe, at: start, expires: start.addingTimeInterval(30 * Clock.day)))
        ledger.ingest(event("psp-renew", .renewal, rail: .stripe,
                            at: start.addingTimeInterval(30 * Clock.day),
                            expires: start.addingTimeInterval(60 * Clock.day)))

        XCTAssertTrue(ledger.verdict(for: "pro.annual", at: start.addingTimeInterval(45 * Clock.day)).allowsAccess)
        XCTAssertFalse(ledger.verdict(for: "pro.annual", at: start.addingTimeInterval(61 * Clock.day)).allowsAccess)
    }
}

final class GraceTests: XCTestCase {

    func testGracePeriodServesAccessAfterExpiry() {
        let start = Clock.at(2026, 10, 1)
        let expiry = start.addingTimeInterval(30 * Clock.day)
        let ledger = EntitlementLedger(
            policy: .subscription,
            events: [purchase("psp-1", rail: .stripe, at: start, expires: expiry)]
        )

        let verdict = ledger.verdict(for: "pro.annual", at: expiry.addingTimeInterval(24 * 3600))
        guard case .grace(let grant, let until) = verdict else {
            return XCTFail("Expected grace, got \(verdict)")
        }
        XCTAssertEqual(grant.rail, .stripe)
        XCTAssertEqual(until, expiry.addingTimeInterval(72 * 3600))
        XCTAssertTrue(verdict.allowsAccess)
    }

    func testGraceExhausted() {
        let start = Clock.at(2026, 10, 1)
        let expiry = start.addingTimeInterval(30 * Clock.day)
        let ledger = EntitlementLedger(
            policy: .subscription,
            events: [purchase("psp-1", rail: .stripe, at: start, expires: expiry)]
        )

        let verdict = ledger.verdict(for: "pro.annual", at: expiry.addingTimeInterval(73 * 3600))
        XCTAssertEqual(verdict, .notEntitled(.expired(at: expiry)))
    }

    /// Grace covers a rail that has gone quiet. It must not cover a rail that told
    /// you, explicitly, that the money went back.
    func testGraceDoesNotApplyAfterRefund() {
        let start = Clock.at(2026, 10, 1)
        let expiry = start.addingTimeInterval(30 * Clock.day)
        var ledger = EntitlementLedger(policy: .subscription)
        ledger.ingest(purchase("psp-1", rail: .stripe, at: start, expires: expiry))
        ledger.ingest(event("psp-refund", .refund, rail: .stripe, at: start.addingTimeInterval(Clock.day)))

        let verdict = ledger.verdict(for: "pro.annual", at: expiry.addingTimeInterval(3600))
        XCTAssertFalse(verdict.allowsAccess)
    }

    func testActiveGrantBeatsAGrantThatIsOnlyAliveOnGrace() {
        let start = Clock.at(2026, 10, 1)
        let shortExpiry = start.addingTimeInterval(10 * Clock.day)
        let longExpiry = start.addingTimeInterval(40 * Clock.day)
        let ledger = EntitlementLedger(
            policy: ReconciliationPolicy(conflictRule: .strictest, gracePeriod: 72 * 3600),
            events: [
                purchase("psp-1", rail: .stripe, at: start, expires: shortExpiry),
                purchase("apple-1", rail: .appleIAP, at: start, expires: longExpiry)
            ]
        )

        // Day 11: Stripe is in grace, Apple is genuinely active. Apple must win even
        // under `.strictest`, which would otherwise prefer the shorter grant.
        let verdict = ledger.verdict(for: "pro.annual", at: start.addingTimeInterval(11 * Clock.day))
        XCTAssertEqual(verdict, .entitled(
            Grant(productID: "pro.annual", rail: .appleIAP, grantedAt: start,
                  expiresAt: longExpiry, sourceEventID: "apple-1")
        ))
    }
}

final class ConflictRuleTests: XCTestCase {

    private func twoRailLedger(rule: ConflictRule) -> (EntitlementLedger, Date) {
        let start = Clock.at(2026, 10, 1)
        let ledger = EntitlementLedger(
            policy: ReconciliationPolicy(conflictRule: rule, gracePeriod: 0),
            events: [
                purchase("apple-1", rail: .appleIAP, at: start, expires: start.addingTimeInterval(30 * Clock.day)),
                purchase("psp-1", rail: .stripe, at: start, expires: start.addingTimeInterval(365 * Clock.day))
            ]
        )
        return (ledger, start)
    }

    func testMostGenerousPicksLongerExpiry() {
        let (ledger, start) = twoRailLedger(rule: .mostGenerous)
        let verdict = ledger.verdict(for: "pro.annual", at: start.addingTimeInterval(Clock.day))
        XCTAssertEqual(verdict.rail, .stripe)
    }

    func testStrictestPicksShorterExpiry() {
        let (ledger, start) = twoRailLedger(rule: .strictest)
        let verdict = ledger.verdict(for: "pro.annual", at: start.addingTimeInterval(Clock.day))
        XCTAssertEqual(verdict.rail, .appleIAP)
    }

    func testRailPriorityPrefersListedRailOverLongerGrant() {
        let (ledger, start) = twoRailLedger(rule: .railPriority([.appleIAP]))
        let verdict = ledger.verdict(for: "pro.annual", at: start.addingTimeInterval(Clock.day))
        XCTAssertEqual(verdict.rail, .appleIAP, "Priority must beat generosity when the rail is listed.")
    }

    func testRailPriorityFallsBackWhenNoListedRailHasAGrant() {
        let (ledger, start) = twoRailLedger(rule: .railPriority([.web]))
        let verdict = ledger.verdict(for: "pro.annual", at: start.addingTimeInterval(Clock.day))
        XCTAssertEqual(verdict.rail, .stripe, "Unlisted rails fall back to most generous.")
    }

    func testNonExpiringGrantBeatsDatedGrant() {
        let start = Clock.at(2026, 10, 1)
        let ledger = EntitlementLedger(
            policy: .mostGenerous,
            events: [
                purchase("apple-1", rail: .appleIAP, at: start, expires: nil),
                purchase("psp-1", rail: .stripe, at: start, expires: start.addingTimeInterval(365 * Clock.day))
            ]
        )
        let verdict = ledger.verdict(for: "pro.annual", at: start.addingTimeInterval(Clock.day))
        XCTAssertEqual(verdict.rail, .appleIAP)
    }
}

final class DoubleBillingTests: XCTestCase {

    func testDualRailGrantsDetectsDoubleBilling() {
        let start = Clock.at(2026, 10, 1)
        let ledger = EntitlementLedger(
            policy: .mostGenerous,
            events: [
                purchase("apple-1", rail: .appleIAP, at: start, expires: start.addingTimeInterval(365 * Clock.day)),
                purchase("psp-1", rail: .stripe, at: start, expires: start.addingTimeInterval(365 * Clock.day)),
                purchase("psp-2", rail: .stripe, product: "coach.monthly", at: start,
                         expires: start.addingTimeInterval(30 * Clock.day))
            ]
        )

        let conflicts = ledger.dualRailGrants(at: start.addingTimeInterval(Clock.day))
        XCTAssertEqual(Array(conflicts.keys), ["pro.annual"])
        XCTAssertEqual(conflicts["pro.annual"]?.count, 2)
    }

    func testNoConflictWhenOnlyOneRailHoldsAGrant() {
        let start = Clock.at(2026, 10, 1)
        let ledger = EntitlementLedger(
            policy: .mostGenerous,
            events: [purchase("apple-1", rail: .appleIAP, at: start,
                              expires: start.addingTimeInterval(365 * Clock.day))]
        )
        XCTAssertTrue(ledger.dualRailGrants(at: start.addingTimeInterval(Clock.day)).isEmpty)
    }

    func testRefundClearsTheConflict() {
        let start = Clock.at(2026, 10, 1)
        var ledger = EntitlementLedger(policy: .mostGenerous)
        ledger.ingest(purchase("apple-1", rail: .appleIAP, at: start, expires: start.addingTimeInterval(365 * Clock.day)))
        ledger.ingest(purchase("psp-1", rail: .stripe, at: start, expires: start.addingTimeInterval(365 * Clock.day)))
        XCTAssertEqual(ledger.dualRailGrants(at: start.addingTimeInterval(Clock.day)).count, 1)

        ledger.ingest(event("psp-refund", .refund, rail: .stripe, at: start.addingTimeInterval(2 * Clock.day)))
        XCTAssertTrue(ledger.dualRailGrants(at: start.addingTimeInterval(3 * Clock.day)).isEmpty)
    }
}
