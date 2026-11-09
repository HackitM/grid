// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Grid",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Grid", targets: ["Grid"]),
    ],
    dependencies: [
        // MIT. PTY-backed VT100/xterm emulator with an AppKit view. Pinned to a minor line.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", .upToNextMinor(from: "1.99.3")),
    ],
    targets: [
        // Pure, UI-free logic (quoting, parsing, ranking, process inspection). Unit tested.
        .target(
            name: "GridCore",
            path: "Sources/GridCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Runs one third-party widget's JavaScript in a sandboxed process with no ambient authority
        // (docs/WIDGETS.md). Talks to GRID only over stdin/stdout.
        .executableTarget(
            name: "GridWidgetHost",
            path: "Sources/GridWidgetHost",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("JavaScriptCore")]
        ),
        .executableTarget(
            name: "Grid",
            dependencies: [
                "GridCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/Grid",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GridCoreTests",
            dependencies: ["GridCore"],
            path: "Tests/GridCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
