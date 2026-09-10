// swift-tools-version: 6.2
import PackageDescription

// Same concurrency setup as the apps: MainActor by default, data types opt out with `nonisolated`.
let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "PetCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PetCore", targets: ["PetCore"]),
    ],
    targets: [
        .target(name: "PetCore", swiftSettings: settings),
        .testTarget(name: "PetCoreTests", dependencies: ["PetCore"], swiftSettings: settings),
    ]
)
