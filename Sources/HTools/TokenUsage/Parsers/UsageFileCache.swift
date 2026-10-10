import Foundation

/// Caches parsed events per source file, keyed by modification time and size.
///
/// Historical session/transcript files are effectively immutable once a session ends;
/// only the file(s) belonging to the currently active session keep growing. Without
/// this cache, every popover open would re-parse the user's entire multi-GB history
/// from scratch. With it, a refresh after the first one only has to re-parse whatever
/// changed since the previous scan.
final class UsageFileCache {
    static let shared = UsageFileCache()

    private struct Entry {
        let modificationDate: Date
        let size: Int
        let events: [UsageEvent]
    }

    private var storage: [String: Entry] = [:]
    private let lock = NSLock()

    func events(for url: URL, parse: () -> [UsageEvent]) -> [UsageEvent] {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modificationDate = attrs?[.modificationDate] as? Date ?? .distantPast
        let size = (attrs?[.size] as? Int) ?? -1
        let key = url.path

        lock.lock()
        if let entry = storage[key], entry.modificationDate == modificationDate, entry.size == size {
            lock.unlock()
            return entry.events
        }
        lock.unlock()

        let events = parse()

        lock.lock()
        storage[key] = Entry(modificationDate: modificationDate, size: size, events: events)
        lock.unlock()

        return events
    }
}
