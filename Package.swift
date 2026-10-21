// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HTools",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "HTools", targets: ["HTools"])
    ],
    targets: [
        .executableTarget(
            name: "HTools",
            path: "Sources/HTools",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
