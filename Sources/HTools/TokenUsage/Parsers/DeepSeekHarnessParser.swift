import Foundation

/// Parses DeepSeek Harness sessions under ~/.dsh/sessions/<project>/<session>/session*.jsonl.zstd.
///
/// Sessions are zstd-compressed, which no system framework can read, so they're piped
/// through the `zstd` command-line tool (`brew install zstd`). Usage sits on
/// `assistant/message` and `compaction/summary` records as `data.usage`, where
/// `inputTokens` already excludes cached tokens. Seeded sessions copy their parent's
/// history, so the message id doubles as the request id to drop those repeats.
enum DeepSeekHarnessParser {
    static func parseAll() -> [UsageEvent] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/sessions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path),
              let zstd = ToolLocator.zstd() else { return [] }

        var files: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        while let file = enumerator?.nextObject() as? URL {
            let name = file.lastPathComponent
            guard name.hasPrefix("session."), name.hasSuffix(".jsonl.zstd") else { continue }
            files.append(file)
        }

        var perFile = [[UsageEvent]](repeating: [], count: files.count)
        perFile.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                buffer[i] = UsageFileCache.shared.events(for: files[i]) {
                    parseFileUncached(files[i], zstd: zstd)
                }
            }
        }
        return perFile.flatMap { $0 }
    }

    private static func parseFileUncached(_ url: URL, zstd: URL) -> [UsageEvent] {
        let process = Process()
        process.executableURL = zstd
        process.arguments = ["-dcq", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        defer { process.waitUntilExit() }

        var events: [UsageEvent] = []
        for data in LineReader(handle: output.fileHandleForReading, containing: "\"usage\"") {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String,
                  type == "assistant/message" || type == "compaction/summary",
                  let time = obj["time"] as? Double,
                  let payload = obj["data"] as? [String: Any],
                  let usage = payload["usage"] as? [String: Any]
            else { continue }

            func tokens(_ key: String) -> Int { max(0, usage[key] as? Int ?? 0) }
            let event = UsageEvent(
                tool: .deepseek,
                date: Date(timeIntervalSince1970: time / 1000),
                inputTokens: tokens("inputTokens"),
                cacheReadTokens: tokens("cacheReadTokens"),
                cacheCreationTokens: tokens("cacheWriteTokens"),
                outputTokens: tokens("outputTokens"),
                reasoningTokens: 0,
                requestID: ((payload["message"] as? [String: Any])?["id"] as? String
                    ?? payload["compactionId"] as? String).map { "dsh:\($0)" }
            )
            guard event.totalTokens > 0 else { continue }
            events.append(event)
        }
        return events
    }
}
