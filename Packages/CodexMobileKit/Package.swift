// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "CodexMobileKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CodexMobileKit", targets: ["CodexMobileKit"]),
    ],
    targets: [
        .target(name: "CodexMobileKit"),
        .testTarget(
            name: "CodexMobileKitTests",
            dependencies: ["CodexMobileKit"]
        ),
    ]
)
