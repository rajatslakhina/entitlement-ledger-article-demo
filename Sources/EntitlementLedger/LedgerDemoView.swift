#if canImport(SwiftUI)
import Foundation
import SwiftUI

/// A worked example: one customer, one product, two rails, and the moment the answer
/// to "do they own this" stops being a single call to StoreKit.
///
/// The scenario is the one that costs money. A customer subscribes through Apple on
/// 1 October for €49.99 a year. On day 31 she sees the cheaper €39.99 annual price
/// you now offer through the payment processor and subscribes again, so she is
/// paying twice — and neither Apple nor the processor can see the other side of it.
/// On day 44 the processor refunds her. An app that treats its PSP webhook as the
/// source of truth locks out a customer who is still paying Apple €49.99 a year.
///
/// Slide the day, change the conflict rule, toggle the refund, and watch the verdict
/// move. Everything on screen comes from `EntitlementLedger`; the view holds no
/// entitlement logic of its own.
@available(iOS 17.0, macOS 14.0, *)
public struct LedgerDemoView: View {

    private enum Rule: String, CaseIterable, Identifiable {
        case mostGenerous = "Most generous"
        case strictest = "Strictest"
        case applePriority = "Apple first"

        var id: String { rawValue }

        var conflictRule: ConflictRule {
            switch self {
            case .mostGenerous: return .mostGenerous
            case .strictest: return .strictest
            case .applePriority: return .railPriority([.appleIAP])
            }
        }
    }

    @State private var rule: Rule = .mostGenerous
    @State private var graceHours: Double = 72
    @State private var dayOffset: Double = 40
    @State private var pspRefunded: Bool = true

    private static let productID = "pro.annual"
    private static let stripe = PaymentRail.alternativeInApp(processor: "Stripe")
    private static let day: TimeInterval = 24 * 60 * 60

    /// 1 October 2026 — the day the unified EU business terms take effect.
    private static let launch: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 1
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }()

    public init() {}

    // MARK: - Scenario

    private var asOf: Date { Self.launch.addingTimeInterval(dayOffset * Self.day) }

    private func makeLedger() -> EntitlementLedger {
        var events: [ReceiptEvent] = [
            ReceiptEvent(
                id: "apple-1",
                rail: .appleIAP,
                productID: Self.productID,
                kind: .purchase,
                effectiveAt: Self.launch,
                expiresAt: Self.launch.addingTimeInterval(365 * Self.day),
                amountMinorUnits: 4999,
                currency: "EUR"
            ),
            ReceiptEvent(
                id: "psp-1",
                rail: Self.stripe,
                productID: Self.productID,
                kind: .purchase,
                effectiveAt: Self.launch.addingTimeInterval(31 * Self.day),
                expiresAt: Self.launch.addingTimeInterval(396 * Self.day),
                amountMinorUnits: 3999,
                currency: "EUR"
            )
        ]
        if pspRefunded {
            events.append(
                ReceiptEvent(
                    id: "psp-refund",
                    rail: Self.stripe,
                    productID: Self.productID,
                    kind: .refund,
                    effectiveAt: Self.launch.addingTimeInterval(44 * Self.day),
                    amountMinorUnits: -3999,
                    currency: "EUR"
                )
            )
        }
        return EntitlementLedger(
            policy: ReconciliationPolicy(conflictRule: rule.conflictRule, gracePeriod: graceHours * 3600),
            events: events
        )
    }

    // MARK: - Body

    public var body: some View {
        let ledger = makeLedger()
        let verdict = ledger.verdict(for: Self.productID, at: asOf)
        let conflicts = ledger.dualRailGrants(at: asOf)

        NavigationStack {
            Form {
                verdictSection(verdict)
                railSection(ledger)
                if !conflicts.isEmpty {
                    conflictSection(conflicts)
                }
                policySection
            }
            .navigationTitle("Entitlement Ledger")
        }
    }

    private func verdictSection(_ verdict: EntitlementVerdict) -> some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: verdict.allowsAccess ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(verdict.allowsAccess ? Color.green : Color.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline(verdict))
                        .font(.headline)
                    Text(detail(verdict))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Verdict on day \(Int(dayOffset))")
        } footer: {
            Text("StoreKit on its own would answer this using only the Apple row below.")
        }
    }

    private func railSection(_ ledger: EntitlementLedger) -> some View {
        Section("What each rail believes") {
            ForEach([PaymentRail.appleIAP, Self.stripe], id: \.identifier) { rail in
                VStack(alignment: .leading, spacing: 2) {
                    Text(rail.description)
                        .font(.subheadline.weight(.medium))
                    Text(describe(ledger.railState(for: Self.productID, on: rail, at: asOf)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func conflictSection(_ conflicts: [String: [Grant]]) -> some View {
        Section("Double billing") {
            ForEach(conflicts.keys.sorted(), id: \.self) { productID in
                let rails = (conflicts[productID] ?? []).map(\.rail.description)
                Label(
                    "\(productID) is open on \(rails.count) rails: \(rails.joined(separator: ", "))",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(Color.orange)
            }
        }
    }

    private var policySection: some View {
        Section("Policy") {
            Picker("Conflict rule", selection: $rule) {
                ForEach(Rule.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            VStack(alignment: .leading) {
                Text("Grace: \(Int(graceHours)) h").font(.caption)
                Slider(value: $graceHours, in: 0...168, step: 24)
            }
            VStack(alignment: .leading) {
                Text("Day \(Int(dayOffset)) after 1 Oct 2026").font(.caption)
                Slider(value: $dayOffset, in: 0...400, step: 1)
            }
            Toggle("Processor refunded on day 44", isOn: $pspRefunded)
        }
    }

    // MARK: - Formatting

    private func headline(_ verdict: EntitlementVerdict) -> String {
        switch verdict {
        case .entitled: return "Access granted"
        case .grace: return "Access granted on grace"
        case .notEntitled: return "Access refused"
        }
    }

    private func detail(_ verdict: EntitlementVerdict) -> String {
        switch verdict {
        case .entitled(let grant):
            return "via \(grant.rail.description)"
        case .grace(let grant, let until):
            return "via \(grant.rail.description), grace ends \(Self.format(until))"
        case .notEntitled(let reason):
            switch reason {
            case .noGrant: return "no rail ever opened a grant"
            case .expired(let date): return "expired \(Self.format(date))"
            case .refunded(let rail, _): return "refunded by \(rail.description)"
            case .revoked(let rail, _): return "revoked by \(rail.description)"
            }
        }
    }

    private func describe(_ state: RailState) -> String {
        switch state {
        case .open(let grant):
            let window = grant.expiresAt.map { "until \(Self.format($0))" } ?? "no expiry"
            return grant.isActive(at: asOf) ? "open, \(window)" : "lapsed, \(window)"
        case .silent:
            return "nothing on file"
        case .closed(let reason):
            switch reason {
            case .refunded(_, let date): return "closed — refunded \(Self.format(date))"
            case .revoked(_, let date): return "closed — revoked \(Self.format(date))"
            case .expired(let date): return "closed — expired \(Self.format(date))"
            case .noGrant: return "nothing on file"
            }
        }
    }

    private static func format(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview {
    LedgerDemoView()
}
#endif
