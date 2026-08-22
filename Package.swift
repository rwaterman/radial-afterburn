// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RadialAfterburn",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "RadialAfterburn", targets: ["RadialAfterburn"])
    ],
    targets: [
        .executableTarget(
            name: "RadialAfterburn",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("AVFoundation")
            ]
        ),
        .testTarget(
            name: "RadialAfterburnTests",
            dependencies: ["RadialAfterburn"]
        )
    ]
)
