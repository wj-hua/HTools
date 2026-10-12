import Foundation

/// Parses pi agent transcripts under ~/.pi/agent/sessions/**/*.jsonl.
enum PiParser {
    static func sessionsDirectory() -> URL? {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
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
        var seenMessageIDs = Set<String>()
        for data in LineReader(handle: handle, containing: "\"usage\"") {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "message",
                  let message = obj["message"] as? [String: Any],
                  message["role"] as? String == "assistant",
                  let usage = message["usage"] as? [String: Any]
            else { continue }

            if let messageID = (obj["id"] as? String) ?? (message["id"] as? String) {
                guard seenMessageIDs.insert(messageID).inserted else { continue }
            }

            let date: Date?
            if let timestampString = (obj["timestamp"] as? String) ?? (message["timestamp"] as? String) {
                date = ISO8601Formatter.parse(timestampString)
            } else if let ms = (message["timestamp"] as? Double) ?? (message["timestamp"] as? Int).map(Double.init) {
                date = Date(timeIntervalSince1970: ms / 1000.0)
            } else {
                date = nil
            }

            guard let eventDate = date else { continue }

            let inputTokens = usage["input"] as? Int ?? 0
            let totalOutput = usage["output"] as? Int ?? 0
            let cacheReadTokens = usage["cacheRead"] as? Int ?? 0
            let cacheCreationTokens = usage["cacheWrite"] as? Int ?? 0
            let reasoningTokens = usage["reasoning"] as? Int ?? 0
            let totalTokens = usage["totalTokens"] as? Int ?? (inputTokens + cacheReadTokens + cacheCreationTokens + totalOutput)

            guard totalTokens > 0 || inputTokens > 0 || totalOutput > 0 else { continue }

            let contentOutput = max(0, totalOutput - reasoningTokens)

            events.append(UsageEvent(
                tool: .pi,
                date: eventDate,
                inputTokens: inputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheCreationTokens: cacheCreationTokens,
                outputTokens: contentOutput,
                reasoningTokens: reasoningTokens
            ))
        }
        return events
    }
}
