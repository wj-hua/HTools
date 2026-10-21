import Foundation

/// Formats token counts using K, M, B, and T suffixes in powers of 1,000.
enum TokenFormat {
    static func string(_ n: Int) -> String {
        let value = Double(n)
        switch n {
        case ..<1_000:
            return n.formatted(.number.grouping(.automatic))
        case ..<1_000_000:
            return String(format: "%.2fK", value / 1_000)
        case ..<1_000_000_000:
            return String(format: "%.2fM", value / 1_000_000)
        case ..<1_000_000_000_000:
            return String(format: "%.2fB", value / 1_000_000_000)
        default:
            return String(format: "%.2fT", value / 1_000_000_000_000)
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
