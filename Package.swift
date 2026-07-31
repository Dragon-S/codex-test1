// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LibmpvNativePiPProbe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "pip-probe", targets: ["PiPProbe"])
    ],
    targets: [
        .systemLibrary(
            name: "CMpv",
            pkgConfig: "mpv",
            providers: [.brew(["mpv"])]
        ),
        .target(
            name: "MPVProbeBridge",
            dependencies: ["CMpv"]
        ),
        .executableTarget(
            name: "PiPProbe",
            dependencies: ["MPVProbeBridge"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo")
            ]
        )
    ]
)
