// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HallE",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "HallE",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/HallE",
            // Localization files are processed normally; the Chrome extension
            // must retain its directory layout so Chrome can load manifest.json
            // plus its service worker/options files as one unpacked extension.
            resources: [
                .process("Resources/en.lproj"),
                .process("Resources/es.lproj"),
                .copy("Resources/CallCaptureExtension"),
            ],
            swiftSettings: [
                // Swift 5 language mode: strict-concurrency errors from AppKit
                // delegate protocols aren't worth it yet; design stays 6-ready.
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "HallETests",
            dependencies: [
                "HallE",
            ],
            path: "Tests/HallETests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "CallCaptureNativeHost",
            path: "Sources/CallCaptureNativeHost",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
