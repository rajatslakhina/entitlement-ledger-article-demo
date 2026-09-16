import SwiftUI
import EntitlementLedger

/// Thin host for `LedgerDemoView`. Everything interesting lives in the package.
@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            LedgerDemoView()
        }
    }
}
