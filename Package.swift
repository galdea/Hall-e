// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HallE",
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
            swiftSettings: [
                // Swift 5 language mode: strict-concurrency errors from AppKit
                // delegate protocols aren't worth it yet; design stays 6-ready.
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "HallETests",
            dependencies: ["HallE"],
            path: "Tests/HallETests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
