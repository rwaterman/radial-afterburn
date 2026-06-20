// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NeonVortex",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "NeonVortex", targets: ["NeonVortex"])
    ],
    targets: [
        .executableTarget(
            name: "NeonVortex",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit")
            ]
        ),
        .testTarget(
            name: "NeonVortexTests",
            dependencies: ["NeonVortex"]
        )
    ]
)
