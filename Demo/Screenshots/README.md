# Screenshots

**This folder is empty on purpose, and that is a disclosure rather than an oversight.**

`Demo.xcodeproj` was not run on the Simulator for the v1.0.0 build, so there are no
screenshots of the running app. The Mac that would have built it had an unrelated
production project open in Xcode at the time, and the automation that builds these
demos stops rather than clicking through someone else's workspace.

What that means for the code in this repo:

- `Sources/EntitlementLedger/*` other than `LedgerDemoView.swift` — compiled and
  tested (52 tests, 0 failures, Swift 6.0.3).
- `Sources/EntitlementLedger/LedgerDemoView.swift` — behind `#if canImport(SwiftUI)`,
  so it compiles to nothing on Linux. Hand-reviewed, never executed.
- `Demo/DemoApp.swift` and `Demo.xcodeproj` — structurally validated, never built.

If you clone this and run it, the first screenshot is yours to take. A PR adding one
is welcome.
