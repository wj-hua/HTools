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
        .target(
            name: "FinderMenuKit",
            path: "Sources/FinderMenuKit",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // Finder 右键菜单扩展（.appex）。由 scripts/build-app.sh 打包进 HTools.app/Contents/PlugIns。
        // _NSExtensionMain 作为入口，由系统的扩展运行时加载 principal class。
        .executableTarget(
            name: "HToolsFinder",
            dependencies: ["FinderMenuKit"],
            path: "Sources/HToolsFinder",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("FinderSync"),
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])
            ]
        ),
        // 右键菜单的后台助手（无界面）。由 scripts/build-app.sh 打包进 HTools.app/Contents/Library。
        .executableTarget(
            name: "HToolsFinderHelper",
            dependencies: ["FinderMenuKit"],
            path: "Sources/HToolsFinderHelper",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "HTools",
            dependencies: ["FinderMenuKit"],
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
