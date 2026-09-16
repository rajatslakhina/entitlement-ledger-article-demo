# Working on EntitlementLedger with an agent

Rules for any coding agent touching this repo. They exist because the failure modes
here are silent: an entitlement bug does not crash, it just quietly serves or refuses
the wrong customer.

## Ground every rule in Apple's text

Every constant in this package traces to a sentence on
[Payment options on the App Store in the EU](https://developer.apple.com/support/payment-options-on-the-app-store-in-the-eu).
Twelve months, seven days, fifteen days, 26/20/15%, the reportable event kinds — all
of them. If you change one, quote the sentence that justifies the new value in the
commit message. If Apple's page does not say it, the doc comment must say that we
chose it and why, the way `AttributionWindow.contains` and `PaymentOptionCommitment`
already do.

## A test that cannot fail is not a test

The suite is the oracle here, because there is no screen to look at that would show
you a wrong verdict. Before adding a test, ask what change to the source would make it
go red. If the answer is "none", you have written an assertion about the language, not
about the ledger. Two specific traps in this domain:

- Asserting a verdict for a scenario where only one rail has any events. Almost every
  reconciliation bug needs two rails to show up.
- Asserting on a grant's fields without asserting on the *verdict*, which is what
  callers actually consume.

## Never let a rail close another rail's grant

`EntitlementLedger.railState(for:on:at:)` filters to a single rail before folding.
That filter is load-bearing. An "optimisation" that folds all events together and then
attributes the result will pass most tests and ship the exact bug this package was
written to prevent — `testRefundOnOneRailDoesNotRevokeAnotherRailsGrant` is the guard.

## Keep the ledger a value type with no I/O

No networking, no StoreKit import, no Date() inside the fold. Every function takes the
instant it should reason about. That is what makes a customer's history replayable
when support asks why someone lost access in March.

## Verification claims must be true

If you did not run the Simulator, the README says you did not. Do not soften
"Verification status" into something that implies a screenshot exists.
