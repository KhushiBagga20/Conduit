// swift-tools-version: 6.2
//
// ConduitKit — everything the two Mac interfaces share.
//
//   ConduitProtocol  Conduit Link wire formats, shared with Android by spec
//   ConduitState     Device state, activity, ConduitStore, ConduitCommands
//   ConduitMedia     The scrcpy client: sockets, parser, decoder, renderer, audio, input
//   ConduitCore      The connection owner: adb, scrcpy servers, devices, sessions
//   ConduitDesign    Design tokens and shared SwiftUI components
//
// Interface code (menu bar, workspace) depends on State, Media and Design.
// Only the app's composition root depends on Core.

import PackageDescription

/// Settings the scrcpy client was developed and physically tested under:
/// Swift 5 language mode, MainActor by default, and Xcode's "approachable
/// concurrency" features. Code moved into ConduitKit keeps them, so it
/// compiles to the same behaviour it had on the phone.
let appSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("DisableOutwardActorInference"),
    .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "ConduitKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ConduitProtocol", targets: ["ConduitProtocol"]),
        .library(name: "ConduitState", targets: ["ConduitState"]),
        .library(name: "ConduitMedia", targets: ["ConduitMedia"]),
        .library(name: "ConduitCore", targets: ["ConduitCore"]),
        .library(name: "ConduitDesign", targets: ["ConduitDesign"]),
    ],
    targets: [
        // Pure value types used from any thread: Swift 6, no default actor.
        .target(
            name: "ConduitProtocol",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ConduitMedia",
            swiftSettings: appSettings
        ),
        .target(
            name: "ConduitState",
            dependencies: ["ConduitProtocol", "ConduitMedia"],
            swiftSettings: appSettings
        ),
        .target(
            name: "ConduitCore",
            dependencies: ["ConduitProtocol", "ConduitState", "ConduitMedia"],
            resources: [.copy("Resources/scrcpy-server-v4.1")],
            swiftSettings: appSettings
        ),
        .target(
            name: "ConduitDesign",
            dependencies: ["ConduitProtocol"],
            swiftSettings: appSettings
        ),
        .testTarget(
            name: "ConduitProtocolTests",
            dependencies: ["ConduitProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ConduitMediaTests",
            dependencies: ["ConduitMedia"],
            swiftSettings: appSettings
        ),
        .testTarget(
            name: "ConduitCoreTests",
            dependencies: ["ConduitCore"],
            swiftSettings: appSettings
        ),
    ]
)
