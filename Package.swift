// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MemoImportCenter",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MemoImportCenter", targets: ["MemoImportCenter"])
    ],
    targets: [
        .executableTarget(
            name: "MemoImportCenter",
            path: "Sources/MemoImportCenter"
        )
    ]
)
