import CoreBluetooth
import Foundation

/// 黑鲨散热背夹（MagCooler 4Pro 等）BLE 协议。
///
/// 非官方实现，协议由实机抓包得到，只在 MagCooler 4Pro（硬件代号 BR42）上验证过。
/// 下行 `[len][cmd][sub][00][val]`，上行 `[0x80|len][cmd][sub][00]…`，
/// 背夹一次只处理一条命令，必须一问一答。
///
/// 另一个自定义服务 `00010203-…1912` 是 Telink 的 OTA 升级通道，不要往里写任何东西。
/// 背夹连上后会主动请求配对，但控制通道不需要配对，链路不加密也能正常使用。
enum CoolerProtocol {
    static let service = CBUUID(string: "0000a0a0-3c17-d293-8e48-14fe2e4da212")
    /// 只支持 Write Without Response。
    static let writeCharacteristic = CBUUID(string: "A001")
    static let notifyCharacteristic = CBUUID(string: "A002")

    /// 广播名前缀。广播名是商品名（如 "Black Shark MagCooler 4pro"），不是硬件代号。
    static let namePrefixes = ["Black Shark MagCooler", "MagCooler", "Mag Cooler", "Fun Cooler", "BR"]

    static func isCooler(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        return namePrefixes.contains { name.lowercased().hasPrefix($0.lowercased()) }
    }

    enum Command: UInt8 {
        case light = 0x01
        case cooling = 0x02
        case firmware = 0x04
        case lightPreset = 0x05
        case heartbeat = 0x06
        case shutdownTimer = 0x08
    }

    /// 定时关闭单位：15 分钟。
    static let shutdownUnitMinutes = 15

    // MARK: - 下行

    static func frame(_ command: Command, sub: UInt8 = 0, value: UInt8 = 0) -> Data {
        Data([0x05, command.rawValue, sub, 0x00, value])
    }

    static let queryCooling = frame(.cooling, sub: 0x10)
    static func setCooling(_ mode: CoolingMode) -> Data { frame(.cooling, value: mode.rawValue) }
    /// 原版切换制冷模式后紧跟着发的配套灯效 preset。
    static func setPreset(_ mode: CoolingMode) -> Data { frame(.lightPreset, value: mode.preset) }
    static let queryFirmware = frame(.firmware, sub: 0x30)
    static let heartbeat = frame(.heartbeat)
    static let queryLowTempProtect = frame(.heartbeat, sub: 0x28, value: 0xFA)
    static func setLowTempProtect(_ on: Bool) -> Data { frame(.heartbeat, sub: 0x28, value: on ? 0xFF : 0x00) }
    static let queryShutdownTimer = frame(.shutdownTimer, sub: 0x08)
    static func setShutdownTimer(units: Int) -> Data { frame(.shutdownTimer, value: UInt8(clamping: units)) }
    static let queryLight = frame(.light, sub: 0x18)

    /// 风扇灯效 47 字节长帧：`2F 01 20 00 [模式] 00 FF FF [周期 u16 LE] [颜色数] [RGB]×n`，补 0。
    static func setLight(effect: UInt8, periodMs: Int, colors: [UInt32]) -> Data {
        var bytes = [UInt8](repeating: 0, count: 47)
        bytes[0...7] = [0x2F, 0x01, 0x20, 0x00, effect, 0x00, 0xFF, 0xFF]
        bytes[8] = UInt8(truncatingIfNeeded: periodMs)
        bytes[9] = UInt8(truncatingIfNeeded: periodMs >> 8)
        bytes[10] = UInt8(colors.count)
        for (index, color) in colors.prefix(3).enumerated() {
            bytes[11 + index * 3] = UInt8(truncatingIfNeeded: color >> 16)
            bytes[12 + index * 3] = UInt8(truncatingIfNeeded: color >> 8)
            bytes[13 + index * 3] = UInt8(truncatingIfNeeded: color)
        }
        return Data(bytes)
    }

    /// 关闭帧照抄原版：模式 01，其余字段任意。
    static let lightOff = setLight(effect: LightEffect.off, periodMs: 0x0E10, colors: [])

    /// 连接后的查询序列（同原版定序）。冷连接后约 1.5 秒内背夹不应答，末尾补查制冷和灯效。
    static let initSequence = [queryCooling, queryLight, queryLowTempProtect, queryFirmware, queryShutdownTimer, queryCooling, queryLight]

    // MARK: - 上行

    enum Response {
        case cooling(CoolingMode?)
        case light(effect: UInt8, periodMs: Int, colors: [UInt32])
        case lowTempProtect(Bool)
        case firmware(String)
        case shutdownTimer(units: Int, elapsedSeconds: Int)
        case temperatures(cold: Int, hot: Int)
        case ack
    }

    /// 解析通知。返回 `(cmd, sub, 内容)`，cmd/sub 用于匹配等待中的请求。
    static func parse(_ data: Data) -> (command: UInt8, sub: UInt8, response: Response)? {
        let b = [UInt8](data)
        guard b.count >= 5, b[0] & 0x80 != 0 else { return nil }
        let command = b[1], sub = b[2]
        let response: Response
        switch (command, sub) {
        case (0x02, 0x10):
            response = .cooling(CoolingMode(rawValue: b[4]))
        case (0x01, 0x18) where b.count >= 11:
            // MTU 23 时只有 20 字节，最多装下 3 色，按实际长度截断。
            let count = min(Int(b[10]), (b.count - 11) / 3)
            let colors = (0..<count).map { i -> UInt32 in
                let offset = 11 + i * 3
                let red = UInt32(b[offset]) << 16
                let green = UInt32(b[offset + 1]) << 8
                return red | green | UInt32(b[offset + 2])
            }
            response = .light(effect: b[4], periodMs: Int(b[8]) | Int(b[9]) << 8, colors: colors)
        case (0x06, 0x28) where b[4] == 0xFF || b[4] == 0x00:
            // 查询回 FF/00；设置 ACK 回 01，归入 ack。
            response = .lowTempProtect(b[4] == 0xFF)
        case (0x04, 0x30):
            let text = String(decoding: b[4...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            response = .firmware(text)
        case (0x08, 0x08) where b.count >= 8:
            response = .shutdownTimer(units: Int(b[5]), elapsedSeconds: Int(b[6]) | Int(b[7]) << 8)
        case (0x06, 0x00) where b.count >= 8:
            // [5] 冷端 ℃，[7] 散热端 ℃（散热端为推断）。
            response = .temperatures(cold: Int(b[5]), hot: Int(b[7]))
        default:
            response = .ack
        }
        return (command, sub, response)
    }
}

/// 制冷模式（cmd 0x02 的值）。数值大小与功率无关。
enum CoolingMode: UInt8, CaseIterable, Identifiable {
    case silent = 0x2D
    case overclock = 0x14
    case smart = 0xFA
    /// 仅开启灯效：风扇和 TEC 停止。切回任一模式即恢复制冷。
    case lightOnly = 0xFB

    var id: UInt8 { rawValue }

    static let coolingModes: [CoolingMode] = [.smart, .silent, .overclock]

    var preset: UInt8 {
        switch self {
        case .silent: return 0x60
        case .overclock: return 0x06
        case .smart: return 0xFA
        case .lightOnly: return 0xFB
        }
    }

    var title: String {
        switch self {
        case .silent: return "静音"
        case .overclock: return "超频"
        case .smart: return "智享"
        case .lightOnly: return "仅灯效"
        }
    }

    var systemImage: String {
        switch self {
        case .silent: return "moon.fill"
        case .overclock: return "bolt.fill"
        case .smart: return "sparkles"
        case .lightOnly: return "lightbulb.fill"
        }
    }

    var detail: String {
        switch self {
        case .silent: return "噪音最小，适合深夜使用"
        case .overclock: return "制冷功率最大，适合大型游戏"
        case .smart: return "按温度实时调节档位，始终保持微凉"
        case .lightOnly: return "制冷已关闭，只亮灯，风扇和 TEC 不工作"
        }
    }
}

/// 风扇灯效模式（长帧第 [4] 字节）。
struct LightEffect: Identifiable, Hashable {
    let id: UInt8
    let name: String
    /// 可选配色 = 颜色个数，0 = 全彩。第一项是默认。
    let schemes: [Int]
    /// 缓慢 / 中 / 快速 三档周期（毫秒）；nil = 不可调。
    let speeds: [Int]?
    var fixedPeriod = 0

    static let off: UInt8 = 0x01

    static let all: [LightEffect] = [
        LightEffect(id: 0x02, name: "彩虹", schemes: [0], speeds: [7200, 3600, 900]),
        LightEffect(id: 0x03, name: "呼吸", schemes: [1], speeds: [3000, 1500, 990]),
        LightEffect(id: 0x04, name: "星光", schemes: [1, 0], speeds: [400, 300, 200]),
        LightEffect(id: 0x05, name: "飞环", schemes: [1], speeds: [2500, 2000, 1500]),
        LightEffect(id: 0x06, name: "长亮", schemes: [1, 2, 3], speeds: nil, fixedPeriod: 0x00FF),
        LightEffect(id: 0x07, name: "追逐", schemes: [2], speeds: [1000, 600, 300]),
        LightEffect(id: 0x08, name: "环绕", schemes: [2], speeds: [1500, 1000, 600]),
        LightEffect(id: 0x09, name: "冲击", schemes: [3], speeds: [1500, 1000, 600]),
        LightEffect(id: 0x0A, name: "缓冲", schemes: [2, 0], speeds: [2500, 2000, 1500]),
        LightEffect(id: 0x0B, name: "刷新", schemes: [0], speeds: nil, fixedPeriod: 300),
        LightEffect(id: 0x0C, name: "跳动", schemes: [0, 1], speeds: [2000, 1500, 1000]),
    ]

    static func find(_ id: UInt8) -> LightEffect? { all.first { $0.id == id } }

    /// 跳动的全彩方案不可调速（实测）。
    func hasSpeed(colorCount: Int) -> Bool { speeds != nil && !(id == 0x0C && colorCount == 0) }

    func period(colorCount: Int, level: Int) -> Int {
        guard let speeds else { return fixedPeriod }
        return hasSpeed(colorCount: colorCount) ? speeds[level] : speeds[1]
    }

    /// 设备回报的周期 → 最接近的档位。
    func level(ofPeriod period: Int) -> Int {
        guard let speeds else { return 1 }
        return speeds.indices.min { abs(speeds[$0] - period) < abs(speeds[$1] - period) } ?? 1
    }

    static func schemeName(_ count: Int) -> String {
        switch count {
        case 0: return "全彩"
        case 1: return "单色"
        case 2: return "双色"
        default: return "三色"
        }
    }
}
