// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NetLab",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(name: "NetLab", targets: ["NetLab"])
    ],
    targets: [
        .target(name: "NetLabCore"),
        .target(name: "NetLabUI", dependencies: ["NetLabCore"]),
        .target(name: "NetLab", dependencies: ["NetLabCore", "NetLabUI"]),
        .testTarget(name: "NetLabCoreTests", dependencies: ["NetLabCore"])
    ]
)
