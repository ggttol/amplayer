// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AmplayerKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AmplayerKit", targets: ["AmplayerKit"]),
    ],
    dependencies: [
        // SMB2/3 客户端（LGPL-2.1，见 THIRD_PARTY_LICENSES.md）
        .package(url: "https://github.com/amosavian/AMSMB2.git", from: "4.0.3"),
    ],
    targets: [
        // 汇总模块：App 只需 import AmplayerKit
        .target(name: "AmplayerKit", dependencies: ["AmplayerCore", "AmplayerAudio", "AmplayerSources", "AmplayerCache", "AmplayerSkin"]),
        .target(name: "AmplayerCore"),
        .target(name: "AmplayerAudio", dependencies: ["AmplayerCore", "MonkeysAudio", "AmplayerObjC"]),
        // 接住 Objective-C 异常（AVAudioEngine 连接失败时抛出，Swift 接不住）
        .target(name: "AmplayerObjC"),
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
        .target(name: "AmplayerSources", dependencies: ["AmplayerCore", .product(name: "AMSMB2", package: "AMSMB2")]),
        .target(name: "AmplayerCache", dependencies: ["AmplayerCore", "AmplayerSources"]),
        .target(name: "AmplayerSkin", dependencies: ["AmplayerCore"]),
        .testTarget(name: "AmplayerKitTests", dependencies: ["AmplayerKit", "AmplayerCore", "AmplayerAudio", "AmplayerSources", "AmplayerCache", "AmplayerSkin"]),
    ],
    cxxLanguageStandard: .cxx17
)
