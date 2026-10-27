import AppKit
import SwiftUI

/// SleepDisabled 是系统级设置，始终从系统读取，避免与其他工具修改后的状态不一致。
struct SleepView: View {
    @State private var isEnabled: Bool?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        CardHeader("防止休眠", systemImage: "moon.zzz")
                        Toggle("合盖后保持运行", isOn: Binding(
                            get: { isEnabled ?? false },
                            set: { setEnabled($0) }
                        ))
                        .disabled(isWorking || isEnabled == nil)

                        Text(isWorking ? "正在更新系统设置…" : (isEnabled == nil ? "无法读取系统休眠设置。" : "阻止系统休眠，屏幕仍可关闭。"))
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CardHeader("使用说明")
                        Text("更改时需要管理员密码。此设置作用于整台 Mac，退出 HTools 或重启后仍然有效；关闭开关可恢复系统休眠。")
                        Text("合盖运行会增加耗电和发热，请保持通风，避免将运行中的电脑放入包内。电量过低或温度过高时系统仍可能休眠或关机。")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !isWorking { refresh() }
        }
    }

    private func refresh() {
        do {
            isEnabled = try Self.readStatus()
            errorMessage = nil
        } catch {
            isEnabled = nil
            errorMessage = error.localizedDescription
        }
    }

    private func setEnabled(_ enabled: Bool) {
        isWorking = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result: String?
            do {
                let command = "/usr/bin/pmset -a disablesleep \(enabled ? 1 : 0)"
                let script = "do shell script \"\(command)\" with administrator privileges"
                _ = try Self.run("/usr/bin/osascript", arguments: ["-e", script])
                result = nil
            } catch {
                result = error.localizedDescription
            }
            DispatchQueue.main.async {
                isWorking = false
                refresh()
                if let result { errorMessage = "未能更改设置：\(result)" }
                else if isEnabled != enabled { errorMessage = "系统未应用请求的设置，请检查系统电源配置。" }
            }
        }
    }

    private static func readStatus() throws -> Bool {
        let output = try run("/usr/bin/pmset", arguments: ["-g"])
        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count == 2, fields[0] == "SleepDisabled" {
                if fields[1] == "1" { return true }
                if fields[1] == "0" { return false }
            }
        }
        throw NSError(domain: "HTools.Sleep", code: 1, userInfo: [NSLocalizedDescriptionKey: "系统未返回休眠设置。"])
    }

    private static func run(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "HTools.Sleep", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text.isEmpty ? "命令执行失败。" : text])
        }
        return text
    }
}
