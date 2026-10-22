// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "OAHCore",
  platforms: [.iOS(.v17)],
  products: [.library(name: "OAHCore", targets: ["OAHCore"])],
  targets: [
    .binaryTarget(name: "OAHMobile", path: "OAHMobile.xcframework"),
    .target(name: "OAHCore", dependencies: ["OAHMobile"]),
  ]
)
