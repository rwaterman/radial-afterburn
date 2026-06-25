// swift-tools-version: 6.2

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
                .linkedFramework("MetalKit")
            ]
        ),
        .testTarget(
            name: "RadialAfterburnTests",
            dependencies: ["RadialAfterburn"]
        )
    ]
)
