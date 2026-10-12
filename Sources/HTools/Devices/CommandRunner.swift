import Foundation

struct CommandResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var stdoutText: String {
        sanitizedText(stdout)
    }

    var stderrText: String {
        sanitizedText(stderr)
    }

    var combinedText: String {
        [stdoutText, stderrText].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func sanitizedText(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(
                of: "\u{001B}\\[[0-9;]*[A-Za-z]",
                with: "",
                options: .regularExpression
            )
        return text
            .components(separatedBy: .newlines)
            .filter { !$0.contains("FreeChannelContinue handle->data is nullptr") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CommandRunner {
    /// 普通 adb / hdc 命令的超时。设备断开或无线连接卡住时命令可能永远不返回，
    /// 不设上限会让设备轮询停住、忙碌状态一直不消失。
    static let defaultTimeout: Duration = .seconds(30)
    /// 安装 APK、拉取录屏、ffmpeg 转码这类耗时与文件大小相关的命令。
    static let longTimeout: Duration = .seconds(600)

    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: Duration = defaultTimeout
    ) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()

            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            if let environment {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            }

            do {
                try process.run()
                let start = ContinuousClock.now
                let watchdog = DispatchWorkItem {
                    guard process.isRunning else { return }
                    process.terminate()
                    // 忽略 SIGTERM 的进程 2 秒后强制结束。
                    let pid = process.processIdentifier
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if process.isRunning { kill(pid, SIGKILL) }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval, execute: watchdog)

                // Read before waitUntilExit so a full pipe cannot deadlock the child process.
                async let out = readToEnd(stdout.fileHandleForReading)
                async let err = readToEnd(stderr.fileHandleForReading)
                process.waitUntilExit()
                watchdog.cancel()

                var errData = await err
                if process.terminationReason == .uncaughtSignal, ContinuousClock.now - start >= timeout {
                    let command = ([executable.lastPathComponent] + arguments).joined(separator: " ")
                    let seconds = Int(timeout.timeInterval)
                    errData.append(Data("\n命令超时（\(seconds) 秒）已终止：\(command)".utf8))
                }
                return await CommandResult(
                    status: process.terminationStatus,
                    stdout: out,
                    stderr: errData
                )
            } catch {
                return CommandResult(
                    status: -1,
                    stdout: Data(),
                    stderr: Data(error.localizedDescription.utf8)
                )
            }
        }.value
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        (try? handle.readToEnd()) ?? Data()
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
