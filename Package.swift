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
    dependencies: [],
    targets: [
        .executableTarget(
            name: "QuotaLens",
            dependencies: [],
            path: "Sources/QuotaLens"
        )
    ]
)
