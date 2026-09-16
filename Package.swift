// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EntitlementLedger",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "EntitlementLedger", targets: ["EntitlementLedger"])
    ],
    targets: [
        .target(name: "EntitlementLedger"),
        .testTarget(
            name: "EntitlementLedgerTests",
            dependencies: ["EntitlementLedger"]
        )
    ]
)
