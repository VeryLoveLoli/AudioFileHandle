// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AudioFileHandle",
    platforms: [
        .iOS(.v12)
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "AudioFileHandle",
            targets: ["AudioFileHandle"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        .package(url: "https://gitee.com/cchsora/AudioUnitComponent", .branch("master")),
        .package(url: "https://gitee.com/cchsora/AudioFileInfo", .branch("master")),
        .package(url: "https://gitee.com/cchsora/WebRTCNS", .branch("master")),
        .package(url: "https://gitee.com/cchsora/Lame", .branch("1.0_noliblame")),
        .package(url: "https://gitee.com/cchsora/LinkedList", .branch("master")),
        .package(url: "https://gitee.com/cchsora/Print", .branch("master")),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "AudioFileHandle",
            dependencies: ["AudioUnitComponent", "AudioFileInfo", "WebRTCNS", "Lame", "LinkedList", "Print"]),
        .testTarget(
            name: "AudioFileHandleTests",
            dependencies: ["AudioFileHandle"]),
    ]
)
