// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacMediaPlayer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MediaPlayerCore", targets: ["MediaPlayerCore"]),
    ],
    targets: [
        .target(name: "MediaPlayerCore"),
        .testTarget(name: "MediaPlayerCoreTests", dependencies: ["MediaPlayerCore"]),
    ]
)
