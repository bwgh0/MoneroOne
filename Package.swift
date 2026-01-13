// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MoneroOne",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "MoneroOne",
            targets: ["MoneroOne"]
        ),
    ],
    dependencies: [
        // MoneroKit will be added here once we have the URL
        // .package(url: "https://github.com/nicksunderland/MoneroKit.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "MoneroOne",
            dependencies: [],
            path: "MoneroOne"
        ),
    ]
)
