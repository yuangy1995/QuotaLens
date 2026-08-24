// swift-tools-version: 6.0
// 该文件由 QuotaLens 工程自动生成

import PackageDescription

let package = Package(
    name: "QuotaLens",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "QuotaLens",
            targets: ["QuotaLens"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "QuotaLens",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/QuotaLens"
        ),
        .testTarget(
            name: "QuotaLensTests",
            dependencies: ["QuotaLens"],
            path: "Tests/QuotaLensTests"
        )
    ]
)
