import Foundation

enum ToolLocator {
    static func adb() -> URL? {
        locate(
            named: "adb",
            extraCandidates: [
                "~/Library/Android/sdk/platform-tools/adb",
                "~/Android/Sdk/platform-tools/adb"
            ]
        )
    }

    static func hdc() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let environment = ProcessInfo.processInfo.environment
        if let explicitPath = environment["HDC_PATH"], isExecutable(explicitPath) {
            return URL(fileURLWithPath: explicitPath)
        }
        let sdkRoots = [
            environment["HARMONYOS_SDK_HOME"],
            environment["DEVECO_SDK_HOME"]
        ].compactMap { $0 }
        let environmentCandidates = sdkRoots.flatMap { root in
            ["\(root)/hdc", "\(root)/toolchains/hdc"]
        } + versionedToolCandidates(in: sdkRoots, tool: "hdc")
        let installedSDKCandidates = versionedToolCandidates(
            in: [
                "\(home)/Library/Huawei/Sdk/openharmony",
                "\(home)/Library/Huawei/Sdk/hmscore"
            ],
            tool: "hdc"
        )
        if let environmentSDKTool = environmentCandidates.first(where: isExecutable) {
            return URL(fileURLWithPath: environmentSDKTool)
        }
        if let pathTool = locate(named: "hdc") {
            return pathTool
        }
        let fallbackCandidates = [
            "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
        ] + installedSDKCandidates
        guard let fallback = fallbackCandidates.first(where: isExecutable) else { return nil }
        return URL(fileURLWithPath: fallback)
    }

    static func ffmpeg() -> URL? {
        locate(named: "ffmpeg")
    }

    static func apkInspector() -> (url: URL, kind: APKInspectorKind)? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sdkRoots = [
            ProcessInfo.processInfo.environment["ANDROID_SDK_ROOT"],
            ProcessInfo.processInfo.environment["ANDROID_HOME"],
            "\(home)/Library/Android/sdk",
            "\(home)/Android/Sdk"
        ].compactMap { $0 }

        for root in sdkRoots {
            let analyzerPaths = [
                "\(root)/cmdline-tools/latest/bin/apkanalyzer",
                "\(root)/tools/bin/apkanalyzer"
            ]
            if let path = analyzerPaths.first(where: isExecutable) {
                return (URL(fileURLWithPath: path), .apkanalyzer)
            }

            let buildTools = URL(fileURLWithPath: root).appendingPathComponent("build-tools")
            if let versions = try? FileManager.default.contentsOfDirectory(
                at: buildTools,
                includingPropertiesForKeys: nil
            ) {
                for version in versions.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                    for tool in ["aapt2", "aapt"] {
                        let candidate = version.appendingPathComponent(tool).path
                        if isExecutable(candidate) {
                            return (URL(fileURLWithPath: candidate), .aapt)
                        }
                    }
                }
            }
        }
        return nil
    }

    private static func locate(named name: String, extraCandidates: [String] = []) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/\(name)" }
        let standardCandidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        let expandedExtras = extraCandidates.map {
            $0.replacingOccurrences(of: "~", with: home, options: [.anchored])
        }
        guard let path = (expandedExtras + pathCandidates + standardCandidates).first(where: isExecutable) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private static func versionedToolCandidates(in roots: [String], tool: String) -> [String] {
        roots.flatMap { root in
            guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root) else {
                return [String]()
            }
            return versions
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { "\(root)/\($0)/toolchains/\(tool)" }
        }
    }

    private static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

enum APKInspectorKind {
    case apkanalyzer
    case aapt
}
