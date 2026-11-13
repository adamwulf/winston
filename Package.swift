// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Winston",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "TelegramLink", targets: ["TelegramLink"]),
        .library(name: "VoiceLoop", targets: ["VoiceLoop"]),
        .library(name: "WinstonLogging", targets: ["WinstonLogging"]),
        .library(name: "WinstonCore", targets: ["WinstonCore"]),
    ],
    dependencies: [
        // TDLibKit release tags are prerelease-style versions, so they must be pinned exactly.
        .package(url: "https://github.com/Swiftgram/TDLibKit", exact: "1.5.2-tdlib-1.8.69-1f390d90"),
        .package(url: "https://github.com/apple/swift-log.git", .upToNextMinor(from: "1.14.0")),
        .package(url: "https://github.com/adamwulf/FellerBuncher.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "TelegramLink",
            dependencies: [
                .product(name: "TDLibKit", package: "TDLibKit"),
                .product(name: "Logging", package: "swift-log"),
                "LogSupport",
            ]
        ),
        .target(
            name: "VoiceLoop",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                "LogSupport",
            ]
        ),
        // The call style shared by the app and the libraries: Logger overloads that take a plain
        // dictionary, and the Error log context helpers. swift-log only.
        .target(
            name: "LogSupport",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // The app's logging facade: bootstrap, the log directory, and the exporter. The only target
        // that imports FellerBuncher.
        .target(
            name: "WinstonLogging",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "FellerBuncher", package: "FellerBuncher"),
                "LogSupport",
            ]
        ),
        // The app's state and logic, with no UI: AppModel, AppSecrets and PhotoFiles. The app
        // target keeps only SwiftUI views and AppKit/UIKit glue. Like the other libraries, it
        // logs through swift-log and LogSupport only.
        .target(
            name: "WinstonCore",
            dependencies: [
                "TelegramLink",
                "VoiceLoop",
                .product(name: "Logging", package: "swift-log"),
                "LogSupport",
            ]
        ),
        .testTarget(
            name: "WinstonCoreTests",
            dependencies: [
                "WinstonCore",
                "TelegramLink",
                "VoiceLoop",
                "TelegramLinkTestSupport",
                "VoiceLoopTestSupport",
            ]
        ),
        // Shared by the test targets: a fake TDLib behind TelegramLink's `package` seam, and
        // builders for TDLibKit values.
        .target(
            name: "TelegramLinkTestSupport",
            dependencies: [
                "TelegramLink",
                .product(name: "TDLibKit", package: "TDLibKit"),
            ],
            path: "Tests/TelegramLinkTestSupport"
        ),
        .testTarget(
            name: "TelegramLinkTests",
            dependencies: [
                "TelegramLink",
                "TelegramLinkTestSupport",
                .product(name: "TDLibKit", package: "TDLibKit"),
            ]
        ),
        // Shared by the test targets: offline audio hardware and a scripted recognizer behind
        // VoiceLoop's `package` seam.
        .target(
            name: "VoiceLoopTestSupport",
            dependencies: ["VoiceLoop"],
            path: "Tests/VoiceLoopTestSupport"
        ),
        .testTarget(name: "VoiceLoopTests", dependencies: ["VoiceLoop", "VoiceLoopTestSupport"]),
        .testTarget(
            name: "WinstonLoggingTests",
            dependencies: [
                "WinstonLogging",
                "LogSupport",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ]
)
