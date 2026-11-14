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
        // Kokoro-82M neural voices (KokoroTTS, CoreML). speech-swift has no release tags, so it is
        // pinned to a commit. This is a fork commit: soniqo/speech-swift 31d676c6 plus a fix so
        // KokoroTTS compiles for x86_64 macOS (Swift's Float16 does not exist there), which the
        // universal Mac archive needs, a fix for the pauses inside long sentences: they are
        // cut into even chunks at phrase starts, short clauses join the chunk beside them, and
        // the silence at those cuts is trimmed, and loading other end-to-end bundles
        // (FluidAudio's 15 s graph) with chunks sized from the loaded graph. Branch
        // agent/kokoro-model-adjustments on the fork.
        .package(url: "https://github.com/adamwulf/speech-swift", revision: "28f91ec131f092b27ea7f22116f26a1626c781e9"),
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
                .product(name: "KokoroTTS", package: "speech-swift"),
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
        .testTarget(
            name: "VoiceLoopTests",
            dependencies: [
                "VoiceLoop",
                "VoiceLoopTestSupport",
                // A recording handler for the voice timeline's lines; no LoggingSystem.bootstrap.
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // iOS only (audio-session interruptions), and a target of its own so it gets its own
        // process: the voice loop hears interruptions process-wide.
        .testTarget(
            name: "VoiceLoopInterruptionTests",
            dependencies: ["VoiceLoop", "VoiceLoopTestSupport"]
        ),
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
