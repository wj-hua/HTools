import Foundation

/// Reads SDK session messages and legacy CLI / VS Code task messages.
enum ClineParser {
    static func parseAll() -> [UsageEvent] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = [home.appendingPathComponent(".cline/data", isDirectory: true)]
        let applicationSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        for editor in ["Code", "Code - Insiders", "VSCodium", "Cursor", "Windsurf"] {
            roots.append(applicationSupport.appendingPathComponent(
                "\(editor)/User/globalStorage/saoudrizwan.claude-dev", isDirectory: true
            ))
        }

        var events: [UsageEvent] = []
        for root in roots {
            for directory in ["sessions", "tasks"] {
                let enumerator = FileManager.default.enumerator(
                    at: root.appendingPathComponent(directory, isDirectory: true),
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                while let file = enumerator?.nextObject() as? URL {
                    guard file.lastPathComponent.hasSuffix(".messages.json")
                            || file.lastPathComponent == "ui_messages.json"
                            || file.lastPathComponent == "cline_messages.json" else { continue }
                    events.append(contentsOf: parseFile(file))
                }
            }
        }
        return events
    }

    static func parseFile(_ url: URL) -> [UsageEvent] {
        UsageFileCache.shared.events(for: url) {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
            let session = json as? [String: Any]
            let messages = (session?["messages"] as? [[String: Any]]) ?? (json as? [[String: Any]]) ?? []
            let sessionID = session?["sessionId"] as? String ?? url.deletingLastPathComponent().lastPathComponent

            return messages.compactMap { message in
                guard let timestamp = message["ts"] as? Double, timestamp > 0 else { return nil }
                let metrics: [String: Any]
                let isSDK: Bool
                if message["role"] as? String == "assistant", let usage = message["metrics"] as? [String: Any] {
                    metrics = usage
                    isSDK = true
                } else if message["type"] as? String == "say",
                          message["say"] as? String == "api_req_started",
                          let text = message["text"] as? String,
                          let usage = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                    metrics = usage
                    isSDK = false
                } else {
                    return nil
                }

                func tokens(_ key: String) -> Int { max(0, metrics[key] as? Int ?? 0) }
                let cacheRead = tokens(isSDK ? "cacheReadTokens" : "cacheReads")
                let cacheWrite = tokens(isSDK ? "cacheWriteTokens" : "cacheWrites")
                let input = tokens(isSDK ? "inputTokens" : "tokensIn")
                let output = tokens(isSDK ? "outputTokens" : "tokensOut")
                // SDK inputTokens includes cached tokens; legacy tokensIn excludes them.
                let uncachedInput = isSDK ? max(0, input - cacheRead - cacheWrite) : input
                guard uncachedInput > 0 || cacheRead > 0 || cacheWrite > 0 || output > 0 else { return nil }
                let messageID = message["id"] as? String ?? String(timestamp)
                return UsageEvent(
                    tool: .cline,
                    date: Date(timeIntervalSince1970: timestamp / 1000),
                    inputTokens: uncachedInput,
                    cacheReadTokens: cacheRead,
                    cacheCreationTokens: cacheWrite,
                    outputTokens: output,
                    reasoningTokens: 0,
                    requestID: "cline:\(sessionID):\(messageID)"
                )
            }
        }
    }
}
