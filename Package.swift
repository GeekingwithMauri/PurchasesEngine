// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PurchasesEngine",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(
            name: "PurchasesEngine",
            targets: ["PurchasesEngine"]
        ),
        .library(
            name: "PurchasesEngineCore",
            targets: ["PurchasesEngineCore"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/RevenueCat/purchases-ios-spm",
            .upToNextMajor(from: "5.0.0")
        )
    ],
    targets: [
        // dependencies: [] is the load-bearing invariant — it keeps every SDK out
        // of the consuming apps' test paths. Do not let it acquire one.
        .target(
            name: "PurchasesEngineCore",
            dependencies: []
        ),
        .target(
            name: "PurchasesEngine",
            dependencies: [
                "PurchasesEngineCore",
                .product(
                    name: "RevenueCat",
                    package: "purchases-ios-spm"
                )
            ]
        ),
        .testTarget(
            name: "PurchasesEngineCoreTests",
            dependencies: ["PurchasesEngineCore"]
        ),
    ]
)
