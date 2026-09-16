// swift-tools-version: 6.0
import PackageDescription

// DiffCore deliberately imports no framework — not SwiftUI, not AppKit, not even
// Foundation where it can be avoided. It holds the parsing, patch-synthesis and
// layout code that has to stay correct and fast, so it must be unit-testable and
// benchmarkable without launching an app.
let package = Package(
    name: "DiffCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "DiffCore", targets: ["DiffCore"])
    ],
    targets: [
        .target(
            name: "DiffCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release)),
            ]
        ),
        .testTarget(
            name: "DiffCoreTests",
            dependencies: ["DiffCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
