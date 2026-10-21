import Foundation

@MainActor
final class ADBService {
    let adbExecutable: URL?
    let hdcExecutable: URL?
    private(set) var selectedDeviceID: DeviceIdentifier?

    init() throws {
        let adbExecutable = ToolLocator.adb()
        let hdcExecutable = ToolLocator.hdc()
        guard adbExecutable != nil || hdcExecutable != nil else {
            throw ADBBarError.bridgeNotFound
        }
        self.adbExecutable = adbExecutable
        self.hdcExecutable = hdcExecutable
    }

    var hasADB: Bool { adbExecutable != nil }
    var hasHDC: Bool { hdcExecutable != nil }

    func selectDevice(_ device: ADBDevice) {
        selectedDeviceID = device.identifier
    }

    func listDevices() async throws -> [ADBDevice] {
        async let adbDevices = listADBDevices()
        async let hdcDevices = listHDCDevices()
        return await (adbDevices + hdcDevices).sorted {
            if $0.bridge != $1.bridge { return $0.bridge.rawValue < $1.bridge.rawValue }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private func listADBDevices() async -> [ADBDevice] {
        guard let adbExecutable else { return [] }
        let result = await run(["devices", "-l"], executable: adbExecutable)
        guard result.status == 0 else { return [] }
        return result.stdoutText
            .split(separator: "\n")
            .dropFirst()
            .compactMap { line in
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard fields.count >= 2 else { return nil }
                let state = ADBDevice.State(rawValue: fields[1]) ?? .unknown
                let model = fields.first(where: { $0.hasPrefix("model:") }).map {
                    String($0.dropFirst("model:".count))
                }
                return ADBDevice(serial: fields[0], state: state, model: model, bridge: .adb)
            }
    }

    private func listHDCDevices() async -> [ADBDevice] {
        guard let hdcExecutable else { return [] }
        var result = await run(["list", "targets", "-v"], executable: hdcExecutable)
        if result.status != 0 {
            result = await run(["list", "targets"], executable: hdcExecutable)
        }
        guard result.status == 0 else { return [] }

        var seen = Set<String>()
        return result.stdoutText
            .split(separator: "\n")
            .compactMap { line in
                let fields = line.split(whereSeparator: \Character.isWhitespace).map(String.init)
                guard let serial = fields.first,
                      !serial.hasPrefix("["),
                      serial.lowercased() != "connectkey",
                      seen.insert(serial).inserted else {
                    return nil
                }
                let isDisconnected = fields.contains {
                    $0.localizedCaseInsensitiveContains("disconnect")
                        || $0.localizedCaseInsensitiveContains("offline")
                }
                return ADBDevice(
                    serial: serial,
                    state: isDisconnected ? .offline : .device,
                    model: nil,
                    bridge: .hdc
                )
            }
    }

    func activeDevice() async throws -> ADBDevice {
        let devices = try await listDevices()
        if let selectedDeviceID,
           let selected = devices.first(where: {
               $0.identifier == selectedDeviceID && $0.state == .device
           }) {
            return selected
        }
        guard let device = devices.first(where: { $0.state == .device }) else {
            throw ADBBarError.noDevice
        }
        selectedDeviceID = device.identifier
        return device
    }

    func activeSerial() async throws -> String {
        try await activeDevice().serial
    }

    func connect(address rawAddress: String) async throws -> String {
        guard let adbExecutable else { throw ADBBarError.adbNotFound }
        let trimmed = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.range(of: #"^[A-Za-z0-9._-]+(?::[0-9]{1,5})?$"#, options: .regularExpression) != nil else {
            throw ADBBarError.invalidAddress
        }
        let address = trimmed.contains(":") ? trimmed : "\(trimmed):5555"
        let result = await run(["connect", address], executable: adbExecutable)
        guard result.status == 0,
              !result.combinedText.localizedCaseInsensitiveContains("failed"),
              !result.combinedText.localizedCaseInsensitiveContains("cannot connect"),
              !result.combinedText.localizedCaseInsensitiveContains("unable to connect") else {
            throw ADBBarError.commandFailed(result.combinedText)
        }
        selectedDeviceID = DeviceIdentifier(bridge: .adb, serial: address)
        UserDefaults.standard.set(address, forKey: "lastWirelessAddress")
        return result.combinedText
    }

    func connectHDC(address rawAddress: String) async throws -> String {
        guard let hdcExecutable else {
            throw ADBBarError.helperNotFound("hdc（请安装 HarmonyOS SDK）")
        }
        let address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty,
              address.range(of: #"^[A-Za-z0-9._-]+(?::[0-9]{1,5})?$"#, options: .regularExpression) != nil,
              validPort(in: address) else {
            throw ADBBarError.invalidAddress
        }
        let result = await run(["tconn", address], executable: hdcExecutable)
        guard hdcCommandSucceeded(result) else {
            throw ADBBarError.commandFailed(result.combinedText)
        }
        let connectedDevices = await listHDCDevices()
        let connected = connectedDevices.first { device in
            device.serial == address
                || (!address.contains(":") && device.serial.hasPrefix("\(address):"))
        }
        selectedDeviceID = connected?.identifier
            ?? DeviceIdentifier(bridge: .hdc, serial: address)
        UserDefaults.standard.set(address, forKey: "lastHDCAddress")
        return result.combinedText.isEmpty ? "HDC 已连接" : result.combinedText
    }

    func pair(address rawAddress: String, pairingCode rawPairingCode: String) async throws -> String {
        guard adbExecutable != nil else { throw ADBBarError.adbNotFound }
        let address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let addressParts = address.split(separator: ":", omittingEmptySubsequences: false)
        guard addressParts.count == 2,
              address.range(
                of: #"^[A-Za-z0-9._-]+:[0-9]{1,5}$"#,
                options: .regularExpression
              ) != nil,
              let port = Int(addressParts[1]),
              (1...65_535).contains(port) else {
            throw ADBBarError.invalidPairingAddress
        }

        let pairingCode = rawPairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pairingCode.range(of: #"^[0-9]{6}$"#, options: .regularExpression) != nil else {
            throw ADBBarError.invalidPairingCode
        }

        return try await performPair(address: address, pairingSecret: pairingCode)
    }

    func pairWithQRCode(serviceName: String, password: String) async throws -> String {
        guard adbExecutable != nil else { throw ADBBarError.adbNotFound }
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()

            // 只用 Bonjour 发现：adb 自己的 mDNS（`adb mdns services`）在设备正常
            // 广播时也经常返回空列表，靠不住，而且每轮都要多起一个 adb 进程。
            let resolver = BonjourPairingServiceResolver(serviceName: serviceName)
            if let address = await resolver.resolve(timeout: 1) {
                try Task.checkCancellation()
                return try await performPair(address: address, pairingSecret: password)
            }

            try await Task.sleep(for: .milliseconds(200))
        }
        throw ADBBarError.qrPairingTimedOut
    }

    func enableWirelessForActiveDevice() async throws -> String {
        let device = try await activeDevice()
        let serial = device.serial
        if device.bridge == .hdc {
            if serial.contains(":") {
                return try await connectHDC(address: serial)
            }
            let interface = try await runShell(["ifconfig", "wlan0"], on: device)
            guard let ip = firstMatch(
                in: interface.stdoutText,
                pattern: #"\binet (?:addr:)?(\d{1,3}(?:\.\d{1,3}){3})\b"#
            ) else {
                throw ADBBarError.ipNotFound
            }
            let mode = await runOnDevice(["tmode", "port", "8710"], device: device)
            guard hdcCommandSucceeded(mode) else {
                throw ADBBarError.commandFailed(mode.combinedText)
            }
            try? await Task.sleep(for: .seconds(1))
            return try await connectHDC(address: "\(ip):8710")
        }

        if serial.contains(":") {
            return try await connect(address: serial)
        }

        let route = await runOnDevice(["shell", "ip", "route"], device: device)
        guard route.status == 0 else {
            throw ADBBarError.commandFailed(route.combinedText)
        }
        guard let ip = firstMatch(in: route.stdoutText, pattern: #"\bsrc\s+(\d{1,3}(?:\.\d{1,3}){3})\b"#) else {
            throw ADBBarError.ipNotFound
        }

        let tcpip = await runOnDevice(["tcpip", "5555"], device: device)
        guard tcpip.status == 0 else {
            throw ADBBarError.commandFailed(tcpip.combinedText)
        }
        try? await Task.sleep(for: .seconds(1))
        return try await connect(address: "\(ip):5555")
    }

    func screenshot() async throws -> Data {
        let device = try await activeDevice()
        return try await screenshot(for: device)
    }

    func screenshot(for device: ADBDevice) async throws -> Data {
        if device.bridge == .adb {
            let result = await runOnDevice(["exec-out", "screencap", "-p"], device: device)
            guard result.status == 0, !result.stdout.isEmpty else {
                throw ADBBarError.commandFailed(result.combinedText)
            }
            return result.stdout
        }

        // HarmonyOS snapshot_display only accepts a .jpeg output path. The menu
        // converts the received image to PNG before placing it on the pasteboard.
        let fileName = "adbbar-screenshot-\(UUID().uuidString).jpeg"
        let remotePath = "/data/local/tmp/\(fileName)"
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let snapshot = await runOnDevice(
            ["shell", "snapshot_display", "-f", remotePath],
            device: device
        )
        guard hdcCommandSucceeded(snapshot) else {
            throw ADBBarError.commandFailed(snapshot.combinedText)
        }
        let receive = await runOnDevice(
            ["file", "recv", remotePath, localURL.path],
            device: device
        )
        let data = try? Data(contentsOf: localURL)
        _ = await runOnDevice(["shell", "rm", remotePath], device: device)
        guard hdcCommandSucceeded(receive),
              let data,
              !data.isEmpty else {
            throw ADBBarError.commandFailed(receive.combinedText)
        }
        return data
    }

    func setLayoutBounds(enabled: Bool) async throws {
        _ = try await activeADBDevice(feature: "布局边界")
        let value = enabled ? "true" : "false"
        try await runShell(["setprop", "debug.layout", value])
        try await runShell(["settings", "put", "global", "debug_layout", enabled ? "1" : "0"])
        _ = try? await runShell(["am", "broadcast", "-a", "android.intent.action.CONFIGURATION_CHANGED"])
    }

    func setOverdraw(enabled: Bool) async throws {
        _ = try await activeADBDevice(feature: "过度绘制")
        try await runShell(["setprop", "debug.hwui.overdraw", enabled ? "show" : "false"])
        _ = try? await runShell(["am", "broadcast", "-a", "android.intent.action.CONFIGURATION_CHANGED"])
    }

    func setPointerLocation(enabled: Bool) async throws {
        _ = try await activeADBDevice(feature: "指针位置")
        try await runShell(["settings", "put", "system", "pointer_location", enabled ? "1" : "0"])
    }

    func developerOptionState() async throws -> DeveloperOptionState {
        let device = try await activeADBDevice(feature: "开发者选项")
        let layout = await runOnDevice(["shell", "getprop", "debug.layout"], device: device)
        let overdraw = await runOnDevice(["shell", "getprop", "debug.hwui.overdraw"], device: device)
        let pointer = await runOnDevice(["shell", "settings", "get", "system", "pointer_location"], device: device)
        return DeveloperOptionState(
            layoutBounds: layout.stdoutText == "true" || layout.stdoutText == "1",
            overdraw: overdraw.stdoutText == "show" || overdraw.stdoutText == "true",
            pointerLocation: pointer.stdoutText == "1"
        )
    }

    func foregroundPackage() async throws -> String? {
        let device = try await activeDevice()
        if device.bridge == .hdc {
            let missions = try await runShell(["aa", "dump", "-l"], on: device)
            return firstMatch(
                in: missions.stdoutText,
                pattern: #"(?s)bundle name \[([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)\].{0,300}?state #FOREGROUND"#
            )
        }

        let activity = await runOnDevice(
            ["shell", "dumpsys", "activity", "activities"],
            device: device
        )
        if activity.status == 0,
           let line = activity.stdoutText
            .split(separator: "\n")
            .map(String.init)
            .first(where: {
                $0.contains("topResumedActivity") || $0.contains("mResumedActivity")
            }),
           let package = packageName(fromActivityLine: line) {
            return package
        }

        let window = await runOnDevice(
            ["shell", "dumpsys", "window", "windows"],
            device: device
        )
        guard window.status == 0,
              let line = window.stdoutText
                .split(separator: "\n")
                .map(String.init)
                .first(where: { $0.contains("mCurrentFocus") || $0.contains("mFocusedApp") }) else {
            return nil
        }
        return packageName(fromActivityLine: line)
    }

    func deviceInfo() async throws -> DeviceInfo {
        let device = try await activeDevice()
        if device.bridge == .hdc {
            return try await hdcDeviceInfo(for: device)
        }

        async let manufacturerResult = runOnDevice(
            ["shell", "getprop", "ro.product.manufacturer"], device: device
        )
        async let modelResult = runOnDevice(["shell", "getprop", "ro.product.model"], device: device)
        async let versionResult = runOnDevice(
            ["shell", "getprop", "ro.build.version.release"], device: device
        )
        async let apiResult = runOnDevice(
            ["shell", "getprop", "ro.build.version.sdk"], device: device
        )
        async let sizeResult = runOnDevice(["shell", "wm", "size"], device: device)
        async let batteryResult = runOnDevice(["shell", "dumpsys", "battery"], device: device)
        async let storageResult = runOnDevice(["shell", "df", "-h", "/data"], device: device)
        async let routeResult = runOnDevice(["shell", "ip", "route"], device: device)

        let (
            manufacturer,
            model,
            version,
            api,
            size,
            battery,
            storage,
            route
        ) = await (
            manufacturerResult,
            modelResult,
            versionResult,
            apiResult,
            sizeResult,
            batteryResult,
            storageResult,
            routeResult
        )

        return DeviceInfo(
            bridge: .adb,
            serial: device.serial,
            manufacturer: outputValue(manufacturer),
            model: outputValue(model),
            systemVersion: outputValue(version),
            apiLevel: outputValue(api),
            resolution: resolutionDescription(from: size.stdoutText),
            battery: batteryDescription(from: battery.stdoutText),
            storage: storageDescription(from: storage.stdoutText),
            ipAddress: firstMatch(
                in: route.stdoutText,
                pattern: #"\bsrc\s+(\d{1,3}(?:\.\d{1,3}){3})\b"#
            ) ?? "未知"
        )
    }

    private func hdcDeviceInfo(for device: ADBDevice) async throws -> DeviceInfo {
        async let manufacturerResult = runOnDevice(
            ["shell", "param", "get", "const.product.manufacturer"], device: device
        )
        async let modelResult = runOnDevice(
            ["shell", "param", "get", "const.product.model"], device: device
        )
        async let versionResult = runOnDevice(
            ["shell", "param", "get", "const.product.software.version"], device: device
        )
        async let apiResult = runOnDevice(
            ["shell", "param", "get", "const.ohos.apiversion"], device: device
        )
        async let displayResult = runOnDevice(
            ["shell", "hidumper", "-s", "DisplayManagerService", "-a", "-a"],
            device: device
        )
        async let batteryResult = runOnDevice(
            ["shell", "hidumper", "-s", "BatteryService", "-a", "-i"],
            device: device
        )
        async let storageResult = runOnDevice(["shell", "df", "-h", "/data"], device: device)
        async let networkResult = runOnDevice(["shell", "ifconfig", "wlan0"], device: device)

        let (manufacturer, model, version, api, display, battery, storage, network) = await (
            manufacturerResult,
            modelResult,
            versionResult,
            apiResult,
            displayResult,
            batteryResult,
            storageResult,
            networkResult
        )
        return DeviceInfo(
            bridge: .hdc,
            serial: device.serial,
            manufacturer: outputValue(manufacturer),
            model: outputValue(model),
            systemVersion: outputValue(version),
            apiLevel: outputValue(api),
            resolution: hdcResolutionDescription(from: display.stdoutText),
            battery: hdcBatteryDescription(from: battery.stdoutText),
            storage: storageDescription(from: storage.stdoutText),
            ipAddress: firstMatch(
                in: network.stdoutText,
                pattern: #"\binet (?:addr:)?(\d{1,3}(?:\.\d{1,3}){3})\b"#
            ) ?? "未知"
        )
    }

    func setDarkMode(_ mode: String) async throws {
        _ = try await activeADBDevice(feature: "深色模式切换")
        try await runShell(["cmd", "uimode", "night", mode])
    }

    func setFontScale(_ scale: Double) async throws {
        _ = try await activeADBDevice(feature: "字体大小调整")
        try await runShell(["settings", "put", "system", "font_scale", String(scale)])
    }

    func setLanguage(_ locale: String) async throws {
        let device = try await activeADBDevice(feature: "系统语言切换")
        let modern = await runOnDevice(
            ["shell", "cmd", "locale", "set-system-locales", locale],
            device: device
        )
        let modernOutput = modern.combinedText.lowercased()
        if modern.status == 0,
           modernOutput.isEmpty {
            return
        }

        // Older Android versions do not expose cmd locale. The system setting is
        // supported by many emulator/OEM builds and is the safest shell fallback.
        try await runShell(["settings", "put", "system", "system_locales", locale])
        _ = try? await runShell(["am", "broadcast", "-a", "android.intent.action.LOCALE_CHANGED"])
    }

    func launchApp(packageName: String) async throws {
        let device = try await activeDevice()
        try await launchApp(packageName: packageName, device: device)
    }

    func forceStopApp(packageName: String) async throws {
        let device = try await activeDevice()
        if device.bridge == .hdc {
            _ = try await runShell(["aa", "force-stop", packageName], on: device)
            return
        }
        try await runShell(["am", "force-stop", packageName])
    }

    func clearAppData(packageName: String) async throws {
        let device = try await activeDevice()
        if device.bridge == .hdc {
            let result = await runOnDevice(
                ["shell", "bm", "clean", "-n", packageName, "-d"],
                device: device
            )
            guard hdcCommandSucceeded(result) else {
                throw ADBBarError.commandFailed(result.combinedText)
            }
            return
        }
        let result = await runOnDevice(["shell", "pm", "clear", packageName], device: device)
        guard androidCommandSucceeded(result) else {
            throw ADBBarError.commandFailed(result.combinedText)
        }
    }

    func uninstallApp(packageName: String) async throws {
        let device = try await activeDevice()
        let result = await runOnDevice(["uninstall", packageName], device: device)
        let succeeded = device.bridge == .adb
            ? androidCommandSucceeded(result)
            : hdcCommandSucceeded(result)
        guard succeeded else {
            throw ADBBarError.commandFailed(result.combinedText)
        }
    }

    func installPackage(at fileURL: URL) async throws -> String? {
        let device = try await activeDevice()
        let fileExtension = fileURL.pathExtension.lowercased()
        let supportedExtensions = device.bridge == .adb
            ? Set(["apk"])
            : Set(["hap", "hsp", "app"])
        guard supportedExtensions.contains(fileExtension) else {
            let expected = supportedExtensions.sorted().map { ".\($0)" }.joined(separator: "、")
            throw ADBBarError.commandFailed(
                "当前选择的是 \(device.bridge.platformName) 设备，请拖入 \(expected) 安装包。"
            )
        }

        if device.bridge == .hdc {
            let result = await runOnDevice(["install", "-r", fileURL.path], device: device, timeout: CommandRunner.longTimeout)
            guard hdcCommandSucceeded(result) else {
                throw ADBBarError.commandFailed(result.combinedText)
            }
            return nil
        }

        let packageName = await packageName(in: fileURL)
        let result = await runOnDevice(["install", "-r", "-d", fileURL.path], device: device, timeout: CommandRunner.longTimeout)
        guard androidCommandSucceeded(result) else {
            throw ADBBarError.commandFailed(result.combinedText)
        }

        if let packageName {
            try? await launchApp(packageName: packageName, device: device)
        }
        return packageName
    }

    func androidRecordingContext() async throws -> (executable: URL, serial: String) {
        let device = try await activeADBDevice(feature: "录屏")
        guard let adbExecutable else { throw ADBBarError.adbNotFound }
        return (adbExecutable, device.serial)
    }

    func runADB(_ arguments: [String], timeout: Duration = CommandRunner.defaultTimeout) async -> CommandResult {
        guard let adbExecutable else {
            return CommandResult(status: -1, stdout: Data(), stderr: Data("未找到 adb".utf8))
        }
        return await run(arguments, executable: adbExecutable, timeout: timeout)
    }

    private func runShell(_ arguments: [String]) async throws {
        let device = try await activeDevice()
        _ = try await runShell(arguments, on: device)
    }

    private func runShell(_ arguments: [String], on device: ADBDevice) async throws -> CommandResult {
        let result = await runOnDevice(["shell"] + arguments, device: device)
        let succeeded = device.bridge == .adb ? result.status == 0 : hdcCommandSucceeded(result)
        guard succeeded else {
            throw ADBBarError.commandFailed(result.combinedText)
        }
        return result
    }

    private func performPair(address: String, pairingSecret: String) async throws -> String {
        guard let adbExecutable else { throw ADBBarError.adbNotFound }
        try await ensureReachable(address: address)
        let result = await run(["pair", address, pairingSecret], executable: adbExecutable)
        guard result.status == 0,
              !result.combinedText.localizedCaseInsensitiveContains("failed") else {
            throw ADBBarError.commandFailed(result.combinedText)
        }
        return result.combinedText.isEmpty ? "无线配对成功" : result.combinedText
    }

    private func ensureReachable(address: String) async throws {
        guard let separator = address.lastIndex(of: ":"),
              let port = UInt16(address[address.index(after: separator)...]) else {
            return
        }
        let host = String(address[..<separator])
        guard await NetworkReachability.canConnect(host: host, port: port, timeout: .seconds(3)) else {
            throw ADBBarError.deviceUnreachable(host)
        }
    }

    private func launchApp(packageName: String, device: ADBDevice) async throws {
        if device.bridge == .hdc {
            let missions = try await runShell(["aa", "dump", "-l"], on: device)
            let escapedBundle = NSRegularExpression.escapedPattern(for: packageName)
            guard let module = firstMatch(
                in: missions.stdoutText,
                pattern: "\\[#\(escapedBundle):([^:\\]]+):[^\\]]+\\]"
            ),
            let ability = firstMatch(
                in: missions.stdoutText,
                pattern: "\\[#\(escapedBundle):[^:\\]]+:([^\\]]+)\\]"
            ) else {
                throw ADBBarError.commandFailed("无法识别该鸿蒙应用的模块和 Ability。")
            }
            _ = try await runShell(
                ["aa", "start", "-b", packageName, "-m", module, "-a", ability],
                on: device
            )
            return
        }

        let launch = await runOnDevice([
            "shell", "monkey", "-p", packageName,
            "-c", "android.intent.category.LAUNCHER", "1"
        ], device: device)
        if launch.status == 0 && !launch.combinedText.contains("No activities found") {
            return
        }

        let resolution = await runOnDevice([
            "shell", "cmd", "package", "resolve-activity", "--brief", packageName
        ], device: device)
        guard let component = resolution.stdoutText
            .split(separator: "\n")
            .map(String.init)
            .last(where: { $0.contains("/") }) else {
            throw ADBBarError.commandFailed(launch.combinedText)
        }

        let start = await runOnDevice(["shell", "am", "start", "-n", component], device: device)
        guard start.status == 0 else {
            throw ADBBarError.commandFailed(start.combinedText)
        }
    }

    private func packageName(in fileURL: URL) async -> String? {
        guard let inspector = ToolLocator.apkInspector() else { return nil }
        let arguments: [String]
        switch inspector.kind {
        case .apkanalyzer:
            arguments = ["manifest", "application-id", fileURL.path]
        case .aapt:
            arguments = ["dump", "badging", fileURL.path]
        }
        let result = await CommandRunner.run(executable: inspector.url, arguments: arguments)
        guard result.status == 0 else { return nil }
        switch inspector.kind {
        case .apkanalyzer:
            return result.stdoutText.split(separator: "\n").first.map(String.init)
        case .aapt:
            return firstMatch(in: result.stdoutText, pattern: #"package:\s+name='([^']+)'"#)
        }
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private func packageName(fromActivityLine line: String) -> String? {
        firstMatch(
            in: line,
            pattern: #"\bu\d+\s+([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)/"#
        )
    }

    private func outputValue(_ result: CommandResult) -> String {
        guard result.status == 0, !result.stdoutText.isEmpty else { return "未知" }
        return result.stdoutText
    }

    private func resolutionDescription(from output: String) -> String {
        firstMatch(in: output, pattern: #"Override size:\s*(\d+x\d+)"#)
            ?? firstMatch(in: output, pattern: #"Physical size:\s*(\d+x\d+)"#)
            ?? "未知"
    }

    private func hdcResolutionDescription(from output: String) -> String {
        guard let width = firstMatch(in: output, pattern: #"(?m)^Width:\s*(\d+)"#),
              let height = firstMatch(in: output, pattern: #"(?m)^Height:\s*(\d+)"#) else {
            return "未知"
        }
        return "\(width)x\(height)"
    }

    private func batteryDescription(from output: String) -> String {
        guard let level = firstMatch(in: output, pattern: #"(?m)^\s*level:\s*(\d+)"#) else {
            return "未知"
        }
        let statusCode = firstMatch(in: output, pattern: #"(?m)^\s*status:\s*(\d+)"#)
        let status: String
        switch statusCode {
        case "2": status = "充电中"
        case "3": status = "使用中"
        case "4": status = "未充电"
        case "5": status = "已充满"
        default: status = "状态未知"
        }
        return "\(level)%（\(status)）"
    }

    private func hdcBatteryDescription(from output: String) -> String {
        guard let capacity = firstMatch(in: output, pattern: #"(?m)^capacity:\s*(\d+)"#) else {
            return "未知"
        }
        let chargingStatus = firstMatch(
            in: output,
            pattern: #"(?m)^chargingStatus:\s*(\d+)"#
        )
        let status: String
        switch chargingStatus {
        case "1": status = "充电中"
        case "2": status = "未充电"
        case "3": status = "已充满"
        default: status = "状态未知"
        }
        return "\(capacity)%（\(status)）"
    }

    private func storageDescription(from output: String) -> String {
        guard let line = output
            .split(separator: "\n")
            .map(String.init)
            .last(where: { $0.split(whereSeparator: \Character.isWhitespace).count >= 5 }) else {
            return "未知"
        }
        let fields = line.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard fields.count >= 5, fields[0] != "Filesystem" else { return "未知" }
        return "已用 \(fields[2]) / 共 \(fields[1])（\(fields[4])）"
    }

    private func activeADBDevice(feature: String) async throws -> ADBDevice {
        let device = try await activeDevice()
        guard device.bridge == .adb else {
            throw ADBBarError.unsupportedFeature(feature, device.bridge)
        }
        return device
    }

    private func runOnDevice(
        _ arguments: [String],
        device: ADBDevice,
        timeout: Duration = CommandRunner.defaultTimeout
    ) async -> CommandResult {
        let executable: URL?
        let prefix: [String]
        switch device.bridge {
        case .adb:
            executable = adbExecutable
            prefix = ["-s", device.serial]
        case .hdc:
            executable = hdcExecutable
            prefix = ["-t", device.serial]
        }
        guard let executable else {
            return CommandResult(
                status: -1,
                stdout: Data(),
                stderr: Data("未找到 \(device.bridge.displayName)".utf8)
            )
        }
        return await run(prefix + arguments, executable: executable, timeout: timeout)
    }

    private func run(
        _ arguments: [String],
        executable: URL,
        timeout: Duration = CommandRunner.defaultTimeout
    ) async -> CommandResult {
        await CommandRunner.run(executable: executable, arguments: arguments, timeout: timeout)
    }

    private func androidCommandSucceeded(_ result: CommandResult) -> Bool {
        result.status == 0 && result.combinedText.localizedCaseInsensitiveContains("success")
    }

    private func hdcCommandSucceeded(_ result: CommandResult) -> Bool {
        guard result.status == 0 else { return false }
        let output = result.combinedText.lowercased()
        return !output.contains("[fail]")
            && !output.contains("failed")
            && !output.contains("failure")
            && !output.contains("error:")
    }

    private func validPort(in address: String) -> Bool {
        guard let separator = address.lastIndex(of: ":") else { return true }
        guard let port = Int(address[address.index(after: separator)...]) else { return false }
        return (1...65_535).contains(port)
    }
}

@MainActor
private final class BonjourPairingServiceResolver: NSObject, @preconcurrency NetServiceDelegate {
    private let serviceName: String
    private var service: NetService?
    private var continuation: CheckedContinuation<String?, Never>?

    init(serviceName: String) {
        self.serviceName = serviceName
    }

    func resolve(timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let service = NetService(
                domain: "local.",
                type: "_adb-tls-pairing._tcp.",
                name: serviceName
            )
            self.service = service
            service.delegate = self
            service.resolve(withTimeout: timeout)
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard sender.port > 0 else {
            finish(with: nil)
            return
        }

        if let ipAddress = ipv4Address(from: sender) {
            finish(with: "\(ipAddress):\(sender.port)")
            return
        }

        guard var hostName = sender.hostName, !hostName.isEmpty else {
            finish(with: nil)
            return
        }
        while hostName.hasSuffix(".") {
            hostName.removeLast()
        }
        finish(with: "\(hostName):\(sender.port)")
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(with: nil)
    }

    private func ipv4Address(from service: NetService) -> String? {
        for addressData in service.addresses ?? [] {
            let address = addressData.withUnsafeBytes { buffer -> String? in
                guard let baseAddress = buffer.baseAddress else { return nil }
                let socketAddress = baseAddress.assumingMemoryBound(to: sockaddr.self)
                guard Int32(socketAddress.pointee.sa_family) == AF_INET else { return nil }

                var ipv4 = baseAddress
                    .assumingMemoryBound(to: sockaddr_in.self)
                    .pointee
                    .sin_addr
                var output = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &ipv4, &output, socklen_t(INET_ADDRSTRLEN)) != nil else {
                    return nil
                }
                let bytes = output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                return String(decoding: bytes, as: UTF8.self)
            }
            if let address {
                return address
            }
        }
        return nil
    }

    private func finish(with address: String?) {
        guard let continuation else { return }
        self.continuation = nil
        service?.stop()
        service?.delegate = nil
        service = nil
        continuation.resume(returning: address)
    }
}
