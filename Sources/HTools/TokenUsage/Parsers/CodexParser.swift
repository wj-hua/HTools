import Foundation

/// Parses Codex CLI rollouts under ~/.codex/sessions/**/*.jsonl.
///
/// Each `token_count` event carries both a cumulative `total_token_usage` and an
/// incremental `last_token_usage` for that turn. We use `last_token_usage` so buckets
/// don't double count the running total.
enum CodexParser {
    static func sessionsDirectory() -> URL? {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    static func parseAll() -> [UsageEvent] {
        guard let dir = sessionsDirectory(),
              FileManager.default.fileExists(atPath: dir.path) else { return [] }

        var files: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        while let file = enumerator?.nextObject() as? URL {
            guard file.pathExtension == "jsonl" else { continue }
            files.append(file)
        }

        var perFile = [[UsageEvent]](repeating: [], count: files.count)
        perFile.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                buffer[i] = parseFile(files[i])
            }
        }
        return perFile.flatMap { $0 }
    }

    /// Almost every line in a rollout is conversation/tool content, not a token_count
    /// event. A cheap substring scan before the full JSON decode skips the vast
    /// majority of (often very large) lines without allocating a parse tree for them.
    private static func parseFile(_ url: URL) -> [UsageEvent] {
        UsageFileCache.shared.events(for: url) { parseFileUncached(url) }
    }

    private static func parseFileUncached(_ url: URL) -> [UsageEvent] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        var events: [UsageEvent] = []
        for line in LineReader(handle: handle) {
            guard line.contains("\"token_count\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = info["last_token_usage"] as? [String: Any]
            else { continue }

            guard let timestampString = obj["timestamp"] as? String,
                  let date = ISO8601Formatter.parse(timestampString)
            else { continue }

            let totalInput = usage["input_tokens"] as? Int ?? 0
            let cachedInput = usage["cached_input_tokens"] as? Int ?? 0
            let totalOutput = usage["output_tokens"] as? Int ?? 0
            let reasoningOutput = usage["reasoning_output_tokens"] as? Int ?? 0
            let totalTokens = usage["total_tokens"] as? Int ?? (totalInput + totalOutput)

            let uncachedInput: Int
            let cacheReadTokens: Int
            let outputTokens: Int
            let reasoningTokens: Int

            if totalInput == 0 && totalOutput == 0 && totalTokens > 0 {
                uncachedInput = totalTokens
                cacheReadTokens = 0
                outputTokens = 0
                reasoningTokens = 0
            } else {
                uncachedInput = max(0, totalInput - cachedInput)
                cacheReadTokens = cachedInput
                outputTokens = max(0, totalOutput - reasoningOutput)
                reasoningTokens = reasoningOutput
            }

            events.append(UsageEvent(
                tool: .codex,
                date: date,
                inputTokens: uncachedInput,
                cacheReadTokens: cacheReadTokens,
                cacheCreationTokens: 0,
                outputTokens: outputTokens,
                reasoningTokens: reasoningTokens
            ))
        }
        return events
    }
}
