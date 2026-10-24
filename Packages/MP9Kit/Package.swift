// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MP9Kit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MP9Kit", targets: ["MP9Kit"]),
    ],
    targets: [
        // 汇总模块：App 只需 import MP9Kit
        .target(name: "MP9Kit", dependencies: ["MP9Core", "MP9Audio", "MP9Sources", "MP9Cache", "MP9Skin"]),
        .target(name: "MP9Core"),
        .target(name: "MP9Audio", dependencies: ["MP9Core"]),
        .target(name: "MP9Sources", dependencies: ["MP9Core"]),
        .target(name: "MP9Cache", dependencies: ["MP9Core", "MP9Sources"]),
        .target(name: "MP9Skin", dependencies: ["MP9Core"]),
        .testTarget(name: "MP9KitTests", dependencies: ["MP9Kit"]),
    ]
)
