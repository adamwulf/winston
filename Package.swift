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
    ],
    dependencies: [
        // TDLibKit release tags are prerelease-style versions, so they must be pinned exactly.
        .package(url: "https://github.com/Swiftgram/TDLibKit", exact: "1.5.2-tdlib-1.8.69-1f390d90"),
    ],
    targets: [
        .target(
            name: "TelegramLink",
            dependencies: [
                .product(name: "TDLibKit", package: "TDLibKit"),
            ]
        ),
        .target(name: "VoiceLoop"),
        .testTarget(
            name: "TelegramLinkTests",
            dependencies: [
                "TelegramLink",
                .product(name: "TDLibKit", package: "TDLibKit"),
            ]
        ),
        .testTarget(name: "VoiceLoopTests", dependencies: ["VoiceLoop"]),
    ]
)
