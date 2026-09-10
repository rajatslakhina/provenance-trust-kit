// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "provenance-trust-kit",
    // Only platforms CI actually builds are declared. watchOS is deliberately absent:
    // `Int` is 32-bit there, and several bounds in this package are derived from
    // `Int.max`, so shipping it without a job that compiles it would be a claim
    // nothing verifies.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ProvenanceTrust", targets: ["ProvenanceTrust"]),
        .library(name: "ProvenanceTrustUI", targets: ["ProvenanceTrustUI"]),
    ],
    targets: [
        .target(name: "ProvenanceTrust", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(
            name: "ProvenanceTrustUI",
            dependencies: ["ProvenanceTrust"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ProvenanceTrustTests",
            dependencies: ["ProvenanceTrust"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
