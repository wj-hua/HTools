import Foundation

/// Streams a file line by line without loading the whole thing into memory using POSIX getline.
///
/// Only lines containing `needle` are yielded, as raw UTF-8 bytes ready for
/// `JSONSerialization`. Transcript lines are mostly conversation/tool content that can
/// be megabytes long; matching on the bytes skips them without building a `String`
/// for every line, and handing back `Data` saves a second copy for the ones we keep.
final class LineReader: Sequence, IteratorProtocol {
    private var filePointer: UnsafeMutablePointer<FILE>?
    private var lineBuffer: UnsafeMutablePointer<CChar>?
    private var lineCap: Int = 0
    private let shouldClose: Bool
    private let needle: [UInt8]

    init?(url: URL, containing needle: String) {
        guard let fp = fopen(url.path, "r") else { return nil }
        self.filePointer = fp
        self.shouldClose = true
        self.needle = Array(needle.utf8)
    }

    init(handle: FileHandle, containing needle: String) {
        let fd = handle.fileDescriptor
        let dupFd = dup(fd)
        if dupFd >= 0 {
            self.filePointer = fdopen(dupFd, "r")
            self.shouldClose = true
        } else {
            self.filePointer = nil
            self.shouldClose = false
        }
        self.needle = Array(needle.utf8)
    }

    deinit {
        if shouldClose, let filePointer {
            fclose(filePointer)
        }
        if let lineBuffer {
            free(lineBuffer)
        }
    }

    func next() -> Data? {
        guard let filePointer else { return nil }
        while true {
            let read = getline(&lineBuffer, &lineCap, filePointer)
            guard read > 0, let lineBuffer else { return nil }
            let found = needle.withUnsafeBytes { memmem(lineBuffer, read, $0.baseAddress, $0.count) }
            guard found != nil else { continue }
            return Data(bytes: lineBuffer, count: read)
        }
    }
}

enum ISO8601Formatter {
    private static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ string: String) -> Date? {
        withFractional.date(from: string) ?? plain.date(from: string)
    }
}
