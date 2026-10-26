import Foundation

struct StethoTarget: Identifiable, Hashable {
    let socketName: String
    var id: String { socketName }

    var processName: String {
        String(socketName.dropFirst("stetho_".count).dropLast("_devtools_remote".count))
    }

    static func discover(in sockets: String) -> [Self] {
        // /proc/net/unix 也包含已连接的 socket；只取监听中的抽象 socket，并去重。
        let names = sockets.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 8, fields[3] == "00010000",
                  let path = fields.last, path.hasPrefix("@stetho_"),
                  path.hasSuffix("_devtools_remote") else { return nil }
            return String(path.dropFirst())
        }
        return Set(names).map { Self(socketName: $0) }.sorted {
            $0.processName.localizedStandardCompare($1.processName) == .orderedAscending
        }
    }
}

struct StethoRequest: Identifiable {
    enum Body: Equatable {
        case notLoaded, loading
        case text(String)
        case base64(String)
        case unavailable(String)

        var storedSize: Int {
            switch self {
            case .text(let text), .base64(let text): return text.utf8.count
            default: return 0
            }
        }
    }

    let id = UUID()
    let requestID: String
    let startedAt: Date
    let timestamp: Double
    let method: String
    let url: String
    let requestHeaders: [String: String]
    let postData: String?
    var status: Int?
    var statusText = ""
    var responseHeaders: [String: String] = [:]
    var mimeType = ""
    var finishedTimestamp: Double?
    var failure: String?
    var body: Body = .notLoaded

    var isFinished: Bool { finishedTimestamp != nil }
    var host: String { URL(string: url)?.host ?? "" }
    var path: String {
        guard let components = URLComponents(string: url) else { return url }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        return path + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
    }

    var durationText: String {
        guard let end = finishedTimestamp else { return "—" }
        let seconds = max(0, end - timestamp)
        return seconds < 1 ? String(format: "%.0f ms", seconds * 1000) : String(format: "%.2f s", seconds)
    }

    var statusLabel: String {
        if failure != nil { return "失败" }
        if let status { return String(status) }
        return isFinished ? "—" : "等待"
    }

    var curl: String {
        var parts = ["curl", "-X", Self.shellQuote(method), Self.shellQuote(url)]
        for key in requestHeaders.keys.sorted() {
            for value in (requestHeaders[key] ?? "").components(separatedBy: "\n") {
                parts += ["-H", Self.shellQuote("\(key): \(value)")]
            }
        }
        if let postData { parts += ["--data-raw", Self.shellQuote(postData)] }
        return parts.joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func headers(_ value: Any?) -> [String: String] {
        guard let fields = value as? [String: Any] else { return [:] }
        return fields.mapValues { $0 as? String ?? String(describing: $0) }
    }

    static func formattedBody(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let formatted = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
              let result = String(data: formatted, encoding: .utf8) else { return text }
        return result
    }
}
