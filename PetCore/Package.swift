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
    dependencies: [
        .package(url: "https://github.com/airbnb/lottie-spm.git", from: "4.6.1"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20"),
    ],
    targets: [
        .target(
            name: "PetCore",
            dependencies: [
                .product(name: "Lottie", package: "lottie-spm"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            resources: [.copy("Resources/pixel-cat.zip")], // built from skins/pixel-cat
            swiftSettings: settings
        ),
        .testTarget(
            name: "PetCoreTests",
            dependencies: ["PetCore", .product(name: "ZIPFoundation", package: "ZIPFoundation")],
            swiftSettings: settings
        ),
    ]
)
