import Foundation

/// Formats token counts using Chinese-style "w" (万, 10^4) and "亿" (10^8) suffixes,
/// since raw counts get unreadable once usage crosses into the millions and billions.
enum TokenFormat {
    static func string(_ n: Int) -> String {
        let value = Double(n)
        switch n {
        case ..<10_000:
            return n.formatted(.number.grouping(.automatic))
        case ..<100_000_000:
            return String(format: "%.2fw", value / 10_000)
        default:
            return String(format: "%.2f亿", value / 100_000_000)
        }
    }

    static func percentage(value: Int, total: Int) -> String {
        guard total > 0, value > 0 else { return "0%" }
        let ratio = Double(value) / Double(total) * 100.0
        if ratio < 0.1 {
            return "<0.1%"
        }
        return String(format: "%.1f%%", ratio)
    }
}
