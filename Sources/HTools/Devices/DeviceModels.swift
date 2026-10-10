import Foundation

enum DeviceBridge: String, Sendable, Hashable {
    case adb
    case hdc

    var displayName: String {
        switch self {
        case .adb: return "ADB"
        case .hdc: return "HDC"
        }
    }

    var platformName: String {
        switch self {
        case .adb: return "Android"
        case .hdc: return "HarmonyOS"
        }
    }
}

struct DeviceIdentifier: Sendable, Hashable {
    let bridge: DeviceBridge
    let serial: String

    var selectionKey: String {
        "\(bridge.rawValue):\(serial)"
    }
}

struct ADBDevice: Sendable, Hashable {
    enum State: String, Sendable {
        case device
        case offline
        case unauthorized
        case unknown
    }

    let serial: String
    let state: State
    let model: String?
    let bridge: DeviceBridge

    var identifier: DeviceIdentifier {
        DeviceIdentifier(bridge: bridge, serial: serial)
    }

    var displayName: String {
        let name = model?.replacingOccurrences(of: "_", with: " ") ?? serial
        return "\(name) · \(bridge.displayName)"
    }

    var isWireless: Bool {
        serial.contains(":")
    }
}

enum RecordingFormat: String, CaseIterable, Sendable {
    case mp4 = "MP4"
    case gif = "GIF"
}

struct DeveloperOptionState: Sendable {
    let layoutBounds: Bool
    let overdraw: Bool
    let pointerLocation: Bool
}

struct DeviceInfo: Sendable {
    let bridge: DeviceBridge
    let serial: String
    let manufacturer: String
    let model: String
    let systemVersion: String
    let apiLevel: String
    let resolution: String
    let battery: String
    let storage: String
    let ipAddress: String

    var formattedText: String {
        [
            "设备：\(manufacturer) \(model)",
            "序列号：\(serial)",
            "系统：\(bridge.platformName) \(systemVersion)（API \(apiLevel)）",
            "分辨率：\(resolution)",
            "电量：\(battery)",
            "存储：\(storage)",
            "IP 地址：\(ipAddress)"
        ].joined(separator: "\n")
    }
}

enum ADBBarError: LocalizedError {
    case adbNotFound
    case bridgeNotFound
    case noDevice
    case unsupportedFeature(String, DeviceBridge)
    case commandFailed(String)
    case invalidAddress
    case invalidPairingAddress
    case invalidPairingCode
    case qrPairingTimedOut
    case deviceUnreachable(String)
    case ipNotFound
    case recordingNotRunning
    case helperNotFound(String)

    var errorDescription: String? {
        switch self {
        case .adbNotFound:
            return "未找到 adb。请先安装 Android SDK Platform-Tools。"
        case .bridgeNotFound:
            return "未找到 adb 或 hdc。请安装 Android Platform-Tools 或 HarmonyOS SDK。"
        case .noDevice:
            return "没有可用设备。请连接 Android/鸿蒙设备并允许 USB 调试。"
        case .unsupportedFeature(let feature, let bridge):
            return "\(feature)暂不支持 \(bridge.platformName)（\(bridge.displayName)）设备。"
        case .commandFailed(let message):
            return message.isEmpty ? "设备命令执行失败。" : message
        case .invalidAddress:
            return "请输入有效的 IP 地址或 IP:端口。"
        case .invalidPairingAddress:
            return "请输入手机无线调试页面显示的 IP 地址和配对端口。"
        case .invalidPairingCode:
            return "请输入手机无线调试页面显示的 6 位配对码。"
        case .qrPairingTimedOut:
            return "等待二维码扫描超时。请确认手机和 Mac 在同一局域网，并重新尝试。"
        case .deviceUnreachable(let host):
            return """
            已发现手机（\(host)），但无法建立连接。手机广播正常，是 Mac 到手机这段网络不通。
            常见原因：Wi-Fi 开启了客户端隔离（学校、公寓、公共网络常见）；手机和 Mac 连在\
            不同的 SSID 或访客网络；手机 Wi-Fi 休眠。
            最快的办法是改用手机热点让 Mac 连上去，或先用 USB 连接后使用「启用无线调试」。
            """
        case .ipNotFound:
            return "无法从设备读取 Wi-Fi IP。请确认手机已连接 Wi-Fi。"
        case .recordingNotRunning:
            return "当前没有正在进行的录屏。"
        case .helperNotFound(let name):
            return "未找到 \(name)。"
        }
    }
}
