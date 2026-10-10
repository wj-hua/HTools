import Foundation
import SQLite3

/// Reads ZCode's per-request usage from ~/.zcode/cli/db/db.sqlite (table `model_usage`).
///
/// The table holds one row per model request — background requests such as
/// session-title generation included, and retried attempts are separate rows that
/// really did consume tokens, so every row counts. ZCode normalizes all providers'
/// usage into "input_tokens is the total prompt size": cached input is already
/// included in it, so the uncached input has to be recovered by subtraction.
/// `output_tokens` likewise includes `reasoning_tokens`.
enum ZCodeParser {
    static func databaseURL() -> URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/cli/db/db.sqlite")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func parseAll() -> [UsageEvent] {
        guard let url = databaseURL() else { return [] }
        // Deliberately not cached via UsageFileCache: the database lives in WAL mode,
        // so new turns land in the -wal file while the main file's mtime/size can stay
        // put and would serve a stale cache. The table is tiny next to transcript
        // files, so re-querying on every refresh is cheap.
        if let events = queryEvents(at: url, immutable: false) {
            return events
        }
        // The read-only connection could not be set up (e.g. the -shm file is not
        // creatable). Fall back to a snapshot read that ignores WAL/locking — it may
        // miss the most recent turns but still shows history.
        return queryEvents(at: url, immutable: true) ?? []
    }

    /// Returns nil when the database could not be opened or queried at all; an empty
    /// array means it was read fine and simply has no usable rows yet.
    private static func queryEvents(at url: URL, immutable: Bool) -> [UsageEvent]? {
        var db: OpaquePointer?
        let openPath: String
        if immutable {
            // Same trick as AgyParser: "immutable=1" treats the file as a fixed
            // snapshot and skips WAL/locking entirely. Requires the URI form.
            guard let escapedPath = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                return nil
            }
            openPath = "file:\(escapedPath)?immutable=1"
        } else {
            // ZCode keeps writing to the live database; a plain read-only connection
            // sees rows that are still sitting in the -wal file. The directory is
            // owned by the user, so creating the -shm side file is fine.
            openPath = url.path
        }
        guard sqlite3_open_v2(openPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)

        let sql = """
            SELECT started_at, input_tokens, output_tokens, reasoning_tokens,
                   cache_creation_input_tokens, cache_read_input_tokens
            FROM model_usage
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }

        var events: [UsageEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            // started_at is a unix epoch timestamp in milliseconds.
            let startedAtMs = sqlite3_column_int64(statement, 0)
            let totalInput = Int(sqlite3_column_int64(statement, 1))
            let totalOutput = Int(sqlite3_column_int64(statement, 2))
            let reasoningTokens = Int(sqlite3_column_int64(statement, 3))
            let cacheCreationTokens = Int(sqlite3_column_int64(statement, 4))
            let cacheReadTokens = Int(sqlite3_column_int64(statement, 5))

            guard totalInput > 0 || totalOutput > 0 || cacheReadTokens > 0 || cacheCreationTokens > 0 else { continue }

            events.append(UsageEvent(
                tool: .zcode,
                date: Date(timeIntervalSince1970: TimeInterval(startedAtMs) / 1000.0),
                inputTokens: max(0, totalInput - cacheReadTokens - cacheCreationTokens),
                cacheReadTokens: cacheReadTokens,
                cacheCreationTokens: cacheCreationTokens,
                outputTokens: max(0, totalOutput - reasoningTokens),
                reasoningTokens: reasoningTokens
            ))
        }
        return events
    }
}
