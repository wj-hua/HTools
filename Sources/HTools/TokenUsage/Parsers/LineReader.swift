import Foundation

/// Streams a file line by line without loading the whole thing into memory using POSIX getline.
final class LineReader: Sequence, IteratorProtocol {
    private var filePointer: UnsafeMutablePointer<FILE>?
    private var lineBuffer: UnsafeMutablePointer<CChar>?
    private var lineCap: Int = 0
    private let shouldClose: Bool

    init?(url: URL) {
        guard let fp = fopen(url.path, "r") else { return nil }
        self.filePointer = fp
        self.shouldClose = true
    }

    init(handle: FileHandle) {
        let fd = handle.fileDescriptor
        let dupFd = dup(fd)
        if dupFd >= 0 {
            self.filePointer = fdopen(dupFd, "r")
            self.shouldClose = true
        } else {
            self.filePointer = nil
            self.shouldClose = false
        }
    }

    deinit {
        if shouldClose, let filePointer {
            fclose(filePointer)
        }
        if let lineBuffer {
            free(lineBuffer)
        }
    }

    func next() -> String? {
        guard let filePointer else { return nil }
        let read = getline(&lineBuffer, &lineCap, filePointer)
        guard read > 0, let lineBuffer else { return nil }
        return String(cString: lineBuffer)
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
