import Foundation

enum MemoryFormat {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return f
    }()

    static func string(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "0 MB" }

        let dBytes = Double(bytes)
        let kb = dBytes / 1024.0
        let mb = kb / 1024.0
        let gb = mb / 1024.0

        if mb < 1.0 {
            return String(format: "%.0f KB", kb)
        } else if gb < 1.0 {
            return String(format: "%.1f MB", mb)
        } else {
            return String(format: "%.2f GB", gb)
        }
    }

    static func percentage(value: UInt64, total: UInt64) -> String {
        guard total > 0, value > 0 else { return "0%" }
        let ratio = (Double(value) / Double(total)) * 100.0
        if ratio < 0.1 {
            return "<0.1%"
        }
        return String(format: "%.1f%%", ratio)
    }
}
