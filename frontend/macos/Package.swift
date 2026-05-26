// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DrWisperMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DrWisperMac", targets: ["DrWisperMac"])
    ],
    targets: [
        .executableTarget(
            name: "DrWisperMac",
            path: "Sources"
        )
    ]
)
