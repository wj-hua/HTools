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
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
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
                // Read before waitUntilExit so a full pipe cannot deadlock the child process.
                async let out = readToEnd(stdout.fileHandleForReading)
                async let err = readToEnd(stderr.fileHandleForReading)
                process.waitUntilExit()
                return await CommandResult(
                    status: process.terminationStatus,
                    stdout: out,
                    stderr: err
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
