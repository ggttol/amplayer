// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MP9Kit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MP9Kit", targets: ["MP9Kit"]),
    ],
    dependencies: [
        // SMB2/3 客户端（LGPL-2.1，见 THIRD_PARTY_LICENSES.md）
        .package(url: "https://github.com/amosavian/AMSMB2.git", from: "4.0.3"),
    ],
    targets: [
        // 汇总模块：App 只需 import MP9Kit
        .target(name: "MP9Kit", dependencies: ["MP9Core", "MP9Audio", "MP9Sources", "MP9Cache", "MP9Skin"]),
        .target(name: "MP9Core"),
        .target(name: "MP9Audio", dependencies: ["MP9Core", "MonkeysAudio"]),
        // Monkey's Audio（APE）解码器，BSD-3-Clause，见 Sources/MonkeysAudio/vendor/License.txt
        .target(
            name: "MonkeysAudio",
            exclude: ["vendor/License.txt", "vendor/README.md"],
            cxxSettings: [
                .define("PLATFORM_APPLE"),
                .headerSearchPath("vendor/Shared"),
                .headerSearchPath("vendor/MACLib"),
                .headerSearchPath("vendor/MACLib/Old"),
            ]
        ),
        .target(name: "MP9Sources", dependencies: ["MP9Core", .product(name: "AMSMB2", package: "AMSMB2")]),
        .target(name: "MP9Cache", dependencies: ["MP9Core", "MP9Sources"]),
        .target(name: "MP9Skin", dependencies: ["MP9Core"]),
        .testTarget(name: "MP9KitTests", dependencies: ["MP9Kit", "MP9Core", "MP9Audio", "MP9Sources", "MP9Cache", "MP9Skin"]),
    ],
    cxxLanguageStandard: .cxx17
)
