# EntitlementLedger

**A single source of truth for "what does this customer own" when your app sells through more than one payment rail.**

On 1 October 2026 Apple's unified EU business terms take effect, and an app on an EU
storefront may offer Apple In-App Purchase, alternative payment processing inside the
app, and out-of-app offers — *at the same time, in the same app*.

The moment you take that second rail, one sentence on Apple's own support page stops
being trivia and starts being your architecture:

> users' purchase history and subscription management will only reflect transactions
> made using Apple In-App Purchase

`Transaction.currentEntitlements` is no longer the answer. It is one input.

This package is the layer that owns the answer instead.

---

## What's in it

| Type | What it decides |
|---|---|
| `PaymentRail` | Which channel a receipt came from, and whether Apple can see it at all |
| `ReceiptEvent` | One normalised receipt: idempotency key, `effectiveAt`, `expiresAt`, six kinds |
| `EntitlementLedger` | Folds every rail's receipts into one `EntitlementVerdict` |
| `ReconciliationPolicy` | Who wins when two rails disagree, and how long grace runs |
| `RailState` | What *one* rail believes — `open`, `silent`, or `closed` |
| `PaymentOptionCommitment` | The 12-month lock on your payment mix, as a check that can fail |
| `AttributionLedger` | The 7-day store-services window for out-of-app sales |
| `TransactionReport` | The monthly report Apple requires, including the rows teams forget |
| `LedgerDemoView` | A SwiftUI walkthrough of the double-billing scenario |

## The three decisions the code makes for you

**A rail can only close its own grants.** A chargeback from your processor must not
revoke a subscription the customer also bought through Apple. This is the bug the
package exists to prevent, and it has a test named after it.

```swift
let stripe = PaymentRail.alternativeInApp(processor: "Stripe")
var ledger = EntitlementLedger(policy: .subscription)

ledger.ingest(ReceiptEvent(id: "apple-1", rail: .appleIAP, productID: "pro.annual",
                           kind: .purchase, effectiveAt: boughtOn, expiresAt: oneYearOut))
ledger.ingest(ReceiptEvent(id: "psp-1", rail: stripe, productID: "pro.annual",
                           kind: .purchase, effectiveAt: boughtOn, expiresAt: oneYearOut))
ledger.ingest(ReceiptEvent(id: "psp-refund", rail: stripe, productID: "pro.annual",
                           kind: .refund, effectiveAt: refundedOn))

ledger.verdict(for: "pro.annual", at: .now).rail   // .appleIAP — still entitled
```

**The verdict does not depend on delivery order.** Webhooks arrive late, out of order
and twice. Events fold on `effectiveAt`, never on arrival time, and duplicate event
IDs are free — so a replayed settlement file and a retried webhook both cost nothing.

**Two open grants for one product is a metric, not an edge case.** `dualRailGrants(at:)`
returns the products where more than one rail is currently paying out. That is a
customer being billed twice by two systems that cannot see each other. Nobody files a
bug for it; it shows up as churn.

```swift
ledger.dualRailGrants(at: .now)
// ["pro.annual": [Grant(rail: .alternativeInApp(processor: "Stripe"), …),
//                 Grant(rail: .appleIAP, …)]]          // sorted by rail identifier
```

## The one-way door

Apple: *"you must maintain that choice across all EU storefronts for 12 months."*

```swift
let commitment = PaymentOptionCommitment(
    selection: [.appleIAP, .alternativeInApp],
    committedOn: octoberFirst2026
)
commitment.evaluate(changeTo: [.appleIAP], on: march2027)
// .locked(until: 2027-10-01, daysRemaining: 214)
```

`PaymentOptionCommitment` takes the conservative reading — *any* delta to the mix is a
change, including adding an option — and says so in its doc comment. If your legal
read differs, change one function and write down who decided. That is the point of
having it in code at all.

It also enforces Guideline 3.1.3(b): a multiplatform service offering only out-of-app
offers fails `defects(in:isMultiplatformService:)`.

## The two rules that quietly cost money

**Seven days.** `AttributionWindow.storeServices` is 604,800 seconds. Apple commissions
out-of-app sales only when they happen within seven days of the link tap, so every
out-of-app sale needs an attribution lookup — scoped per customer as well as per
product, because one person's tap must not earn a commission on someone else's sale. The boundary at exactly seven days is
undefined in Apple's text; this treats it as inclusive, which errs towards paying a
commission you might not owe rather than under-reporting to a party with audit rights.

**Abandoned transactions are reportable.** Apple requires "refunds, corrections,
renewals, one-time purchases, and transactions that didn't result in a purchase."
Nothing happened, so nothing got logged, so the report is wrong. `ReceiptEventKind.abandoned`
exists for exactly that row, and `TransactionReport` has a test asserting it appears.
The report is due within 15 days of month end — for September 2026, the last full day
to file is 15 October.

## Running it

```bash
git clone https://github.com/rajatslakhina/entitlement-ledger-article-demo.git
cd entitlement-ledger-article-demo
swift test            # 52 tests
open Demo.xcodeproj   # pick a Simulator, Build & Run
```

One repo, one clone. `Demo.xcodeproj` consumes the library through a local package
reference (`XCLocalSwiftPackageReference` with `relativePath = .`), so there is no
second checkout and no remote dependency to resolve.

## Verification status

Stated plainly, because the difference matters:

- **`swift build` — clean, zero warnings.** Swift 6.0.3, Linux aarch64.
- **`swift test` — 52 tests, 0 failures.** Covering idempotency, order-independence,
  cross-rail refund isolation, grace windows, all three conflict rules, double-billing
  detection, the 12-month lock, the 7-day attribution boundary on both sides, customer
  and product scoping of link taps, and the monthly report's month and year boundaries.
- **`Demo.xcodeproj` was NOT run on Simulator, and there are no screenshots of the
  running app.** The machine that would have built it had an unrelated production
  project open in Xcode, and this project's automation stops rather than clicking
  through someone else's workspace. `LedgerDemoView.swift` sits behind
  `#if canImport(SwiftUI)`, so the Linux build compiles it to nothing — it has been
  hand-reviewed against the SwiftUI API surface for iOS 17, not compiled. Treat the
  library as verified and the view as unverified.

`project.pbxproj` was hand-authored and checked for brace/paren balance and dangling
object references (20 objects, all defined, all referenced).

## Source

Every rule encoded here traces to Apple's own page, not to a summary of it:
[Payment options on the App Store in the EU](https://developer.apple.com/support/payment-options-on-the-app-store-in-the-eu)
and [Changes for apps in the European Union](https://developer.apple.com/news/?id=gmws0jgp) (18 August 2026).

Article: (added after publish)

## Licence

MIT.
