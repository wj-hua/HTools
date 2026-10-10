import Foundation
import SQLite3

/// Parses agy (Antigravity CLI) conversation databases under
/// ~/.gemini/antigravity-cli/conversations/*.db.
enum AgyParser {
    static func conversationsDirectory() -> URL? {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/conversations", isDirectory: true)
    }

    static func parseAll() -> [UsageEvent] {
        guard let dir = conversationsDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }

        let dbFiles = files.filter { $0.pathExtension == "db" }
        var perFile = [[UsageEvent]](repeating: [], count: dbFiles.count)
        perFile.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: dbFiles.count) { i in
                buffer[i] = parseDatabase(at: dbFiles[i])
            }
        }
        return perFile.flatMap { $0 }
    }

    private static func parseDatabase(at url: URL) -> [UsageEvent] {
        UsageFileCache.shared.events(for: url) { parseDatabaseUncached(at: url) }
    }

    private static func parseDatabaseUncached(at url: URL) -> [UsageEvent] {
        // These databases are actively written by the agy CLI in WAL mode. A plain
        // SQLITE_OPEN_READONLY connection still needs write access to the -shm file to
        // read WAL data, which we don't want (and may not have); "immutable=1" tells
        // SQLite to treat the file as a fixed snapshot and skip WAL/locking entirely.
        guard let escapedPath = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return []
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            "file:\(escapedPath)?immutable=1",
            &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
            nil
        ) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        let genMeta = readBlobs(db: db, sql: "SELECT idx, data FROM gen_metadata")
        guard !genMeta.isEmpty else { return [] }

        let stepTimestamps = readStepTimestamps(db: db)

        var events: [UsageEvent] = []
        for (idx, blob) in genMeta {
            guard let fields = AgyProtoReader.parse(blob),
                  let f1 = AgyProtoReader.first(fields, number: 1),
                  let nested = f1.nested
            else { continue }

            // Sub-fields of the LLM call metrics message (field 4): 2 = uncached prompt
            // tokens, 5 = cached prompt tokens, 3 = total output tokens, 9 = thinking
            // tokens, 10 = content tokens (defaults to total output minus thinking).
            var uncachedInput = 0
            var cachedInput = 0
            var totalOutput = 0
            var thinkingTokens = 0
            var contentTokens: Int?
            for f in nested where f.number == 4 {
                guard let tokenFields = f.nested else { continue }
                for tf in tokenFields {
                    switch tf.number {
                    // Guard against varints that overflow Int (corrupt/unknown data):
                    // treat them as ignored rather than crashing the whole app.
                    case 2: uncachedInput = Int(exactly: tf.varint) ?? 0
                    case 5: cachedInput = Int(exactly: tf.varint) ?? 0
                    case 3: totalOutput = Int(exactly: tf.varint) ?? 0
                    case 9: thinkingTokens = Int(exactly: tf.varint) ?? 0
                    case 10: contentTokens = Int(exactly: tf.varint)
                    default: break
                    }
                }
            }
            let resolvedContentTokens = contentTokens ?? max(0, totalOutput - thinkingTokens)

            guard uncachedInput > 0 || cachedInput > 0 || totalOutput > 0 else { continue }

            let date = stepTimestamps[idx] ?? Date()
            events.append(UsageEvent(
                tool: .agy,
                date: date,
                inputTokens: uncachedInput,
                cacheReadTokens: cachedInput,
                cacheCreationTokens: 0,
                outputTokens: resolvedContentTokens,
                reasoningTokens: thinkingTokens
            ))
        }
        return events
    }

    private static func readBlobs(db: OpaquePointer, sql: String) -> [(Int, Data)] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }

        var results: [(Int, Data)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let idx = Int(sqlite3_column_int(statement, 0))
            guard let blobPointer = sqlite3_column_blob(statement, 1) else { continue }
            let length = Int(sqlite3_column_bytes(statement, 1))
            guard length > 0 else { continue }
            let data = Data(bytes: blobPointer, count: length)
            results.append((idx, data))
        }
        return results
    }

    /// Finds the earliest plausible unix timestamp nested anywhere inside a step's
    /// payload, keyed by the step's `idx` (which lines up with `gen_metadata.idx`).
    private static func readStepTimestamps(db: OpaquePointer) -> [Int: Date] {
        let rows = readBlobs(db: db, sql: "SELECT idx, step_payload FROM steps")
        var result: [Int: Date] = [:]
        for (idx, blob) in rows {
            guard let fields = AgyProtoReader.parse(blob) else { continue }
            if let date = earliestTimestamp(in: fields) {
                result[idx] = date
            }
        }
        return result
    }

    private static let minPlausible: UInt64 = 946_684_800   // 2000-01-01
    private static let maxPlausible: UInt64 = 4_102_444_800 // 2100-01-01

    private static func earliestTimestamp(in fields: [AgyField]) -> Date? {
        var best: Date?
        func visit(_ fs: [AgyField]) {
            for f in fs {
                guard let nested = f.nested else { continue }
                if let seconds = timestampSeconds(nested), seconds >= minPlausible, seconds <= maxPlausible {
                    let candidate = Date(timeIntervalSince1970: TimeInterval(seconds))
                    if best == nil || candidate < best! { best = candidate }
                }
                visit(nested)
            }
        }
        visit(fields)
        return best
    }

    /// A nested message that looks like `google.protobuf.Timestamp`: only fields 1
    /// (seconds, varint) and 2 (nanos, varint) present, with field 1 required.
    private static func timestampSeconds(_ fields: [AgyField]) -> UInt64? {
        var seconds: UInt64?
        for f in fields {
            guard f.wire == .varint else { return nil }
            switch f.number {
            case 1: seconds = f.varint
            case 2: break
            default: return nil
            }
        }
        return seconds
    }
}
