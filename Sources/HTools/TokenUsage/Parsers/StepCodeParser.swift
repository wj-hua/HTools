import Foundation

/// Parses StepCode (the `step` CLI) session transcripts under
/// ~/.stepcode/agent/sessions, one JSONL file per working directory.
///
/// Sessions are JSONL trees — one object per line, each with a `type` field. The
/// interesting lines are `message` entries holding an assistant turn, whose
/// `message.usage` uses the same field names as pi (`input`, `output`,
/// `cacheRead`, `cacheWrite`, `reasoning`, `totalTokens`), with `output` already
/// including the reasoning tokens.
enum StepCodeParser {
    static func sessionsDirectory() -> URL? {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".stepcode/agent/sessions", isDirectory: true)
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

    private static func parseFile(_ url: URL) -> [UsageEvent] {
        UsageFileCache.shared.events(for: url) { parseFileUncached(url) }
    }

    private static func parseFileUncached(_ url: URL) -> [UsageEvent] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        var events: [UsageEvent] = []
        for line in LineReader(handle: handle) {
            guard line.contains("\"usage\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "message",
                  let message = obj["message"] as? [String: Any],
                  message["role"] as? String == "assistant",
                  let usage = message["usage"] as? [String: Any],
                  let date = timestamp(entry: obj, message: message)
            else { continue }

            let inputTokens = usage["input"] as? Int ?? 0
            let totalOutput = usage["output"] as? Int ?? 0
            let cacheReadTokens = usage["cacheRead"] as? Int ?? 0
            let cacheCreationTokens = usage["cacheWrite"] as? Int ?? 0
            let reasoningTokens = usage["reasoning"] as? Int ?? 0

            guard inputTokens > 0 || totalOutput > 0 || cacheReadTokens > 0 || cacheCreationTokens > 0 else {
                continue
            }

            events.append(UsageEvent(
                tool: .stepcode,
                date: date,
                inputTokens: inputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheCreationTokens: cacheCreationTokens,
                outputTokens: max(0, totalOutput - reasoningTokens),
                reasoningTokens: reasoningTokens,
                requestID: requestID(entry: obj, message: message)
            ))
        }
        return events
    }

    /// Identifies the model request behind an entry so that the same request is only
    /// counted once: `step --fork` and `/clone` copy a branch's entries verbatim into
    /// a new session file, keeping both the entry ids and the response ids, which
    /// would otherwise double-count the copied turns.
    ///
    /// Entry ids are only the first 8 characters of a UUID, so they can collide
    /// between unrelated sessions; pairing them with the response id (unique per
    /// model request) keeps the key safe while still matching forked copies.
    private static func requestID(entry: [String: Any], message: [String: Any]) -> String {
        let entryID = entry["id"] as? String ?? ""
        let responseID = message["responseId"] as? String ?? ""
        return "\(entryID)\u{0}\(responseID)"
    }

    /// Entry-level ISO 8601 timestamp, falling back to the message's own timestamp
    /// (ISO 8601 string, or epoch milliseconds as a number).
    private static func timestamp(entry: [String: Any], message: [String: Any]) -> Date? {
        if let string = entry["timestamp"] as? String, let date = ISO8601Formatter.parse(string) {
            return date
        }
        if let string = message["timestamp"] as? String, let date = ISO8601Formatter.parse(string) {
            return date
        }
        if let milliseconds = message["timestamp"] as? Double {
            return Date(timeIntervalSince1970: milliseconds / 1000.0)
        }
        return nil
    }
}
