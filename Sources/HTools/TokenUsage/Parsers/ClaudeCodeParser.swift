import Foundation

/// Parses Claude Code transcripts under ~/.claude/projects/**/*.jsonl.
///
/// Each assistant turn can appear more than once in the transcript (e.g. sidechain
/// duplicates); the same `message.id` is reused for those repeats, so we dedupe on it
/// to avoid double-counting tokens.
enum ClaudeCodeParser {
    static func projectsDirectory() -> URL? {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    static func parseAll() -> [UsageEvent] {
        guard let dir = projectsDirectory(),
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

        // Duplicate message.id's only ever repeat within the same transcript file, so
        // it's safe to dedupe per file and parse files concurrently.
        var perFile = [[UsageEvent]](repeating: [], count: files.count)
        perFile.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                buffer[i] = parseFile(files[i])
            }
        }
        return perFile.flatMap { $0 }
    }

    private static func parseFile(_ url: URL) -> [UsageEvent] {
        UsageFileCache.shared.events(for: url) { parseFileUncached(url) }
    }

    private static func parseFileUncached(_ url: URL) -> [UsageEvent] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        var events: [UsageEvent] = []
        var seenMessageIDs = Set<String>()
        for line in LineReader(handle: handle) {
            guard line.contains("\"assistant\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }

            if let messageID = message["id"] as? String {
                guard seenMessageIDs.insert(messageID).inserted else { continue }
            }

            guard let timestampString = obj["timestamp"] as? String,
                  let date = ISO8601Formatter.parse(timestampString)
            else { continue }

            let totalOutput = usage["output_tokens"] as? Int ?? 0
            let details = usage["output_tokens_details"] as? [String: Any]
            let thinkingTokens = details?["thinking_tokens"] as? Int ?? 0
            let contentOutput = max(0, totalOutput - thinkingTokens)

            events.append(UsageEvent(
                tool: .claude,
                date: date,
                inputTokens: usage["input_tokens"] as? Int ?? 0,
                cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0,
                cacheCreationTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
                outputTokens: contentOutput,
                reasoningTokens: thinkingTokens
            ))
        }
        return events
    }
}
