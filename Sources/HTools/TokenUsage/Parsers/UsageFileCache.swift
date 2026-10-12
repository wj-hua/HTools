import Foundation

/// Caches parsed events per source file, keyed by modification time and size.
///
/// Historical session/transcript files are effectively immutable once a session ends;
/// only the file(s) belonging to the currently active session keep growing. Without
/// this cache, every refresh would re-parse the user's entire multi-GB history from
/// scratch. With it, a refresh only has to re-parse whatever changed since the
/// previous scan. The cache is also saved to disk after each scan, so a fresh launch
/// starts from it instead of parsing everything again.
final class UsageFileCache {
    static let shared = UsageFileCache()

    /// Bump whenever a parser's output changes for the same input file, so events
    /// saved by an older build are discarded instead of reused.
    private static let formatVersion = 2

    private struct Stamp: Codable, Equatable {
        let modificationDate: Date
        let size: Int
    }

    private struct Entry: Codable {
        let stamps: [Stamp]
        let events: [UsageEvent]
    }

    private struct Persisted: Codable {
        let version: Int
        let entries: [String: Entry]
    }

    private let fileURL: URL
    private var storage: [String: Entry]
    /// Files looked up since the last `save()`; anything else belongs to a deleted
    /// session and is dropped when saving.
    private var visited = Set<String>()
    private var isDirty = false
    private let lock = NSLock()

    init(fileURL: URL = UsageFileCache.defaultFileURL()) {
        self.fileURL = fileURL
        self.storage = Self.load(from: fileURL)
    }

    /// `companions` are side files whose changes should also invalidate the entry,
    /// e.g. a SQLite `-wal` file: in WAL mode new rows land there while the main
    /// file's mtime and size stay put.
    func events(for url: URL, companions: [URL] = [], parse: () -> [UsageEvent]) -> [UsageEvent] {
        let stamps = ([url] + companions).map(Self.stamp(of:))
        let key = url.path

        lock.lock()
        visited.insert(key)
        if let entry = storage[key], entry.stamps == stamps {
            lock.unlock()
            return entry.events
        }
        lock.unlock()

        let events = parse()

        lock.lock()
        storage[key] = Entry(stamps: stamps, events: events)
        isDirty = true
        lock.unlock()

        return events
    }

    /// Writes the cache to disk. Call once after a full scan of every source.
    func save() {
        lock.lock()
        let staleKeys = Set(storage.keys).subtracting(visited)
        for key in staleKeys { storage[key] = nil }
        let needsWrite = isDirty || !staleKeys.isEmpty
        let snapshot = storage
        visited.removeAll()
        isDirty = false
        lock.unlock()

        guard needsWrite else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(Persisted(version: Self.formatVersion, entries: snapshot))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // The cache is only an optimization; a failed write just means the next
            // launch parses from scratch.
        }
    }

    private static func load(from url: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: url),
              let persisted = try? PropertyListDecoder().decode(Persisted.self, from: data),
              persisted.version == formatVersion
        else { return [:] }
        return persisted.entries
    }

    private static func stamp(of url: URL) -> Stamp {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return Stamp(
            modificationDate: attrs?[.modificationDate] as? Date ?? .distantPast,
            size: (attrs?[.size] as? Int) ?? -1
        )
    }

    private static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mino.htools", isDirectory: true)
            .appendingPathComponent("usage-cache.plist", isDirectory: false)
    }
}
