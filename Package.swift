// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "VoiceMemoRenamer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VoiceMemoRenamer", targets: ["VoiceMemoRenamer"])
    ],
    targets: [
        .executableTarget(
            name: "VoiceMemoRenamer",
            path: "Sources/VoiceMemoRenamer"
        )
    ]
)
