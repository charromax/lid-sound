// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "lid-sound",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "lid-sound", targets: ["lid-sound"])
    ],
    targets: [
        .executableTarget(
            name: "lid-sound",
            resources: [
                .process("sounds")
            ]
        )
    ]
)
