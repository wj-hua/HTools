import SwiftUI

enum Tool: String, CaseIterable, Identifiable, Codable {
    case claude = "Claude Code"
    case codex = "Codex"
    case agy = "agy"
    case cline = "Cline"

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .agy: return "agy"
        case .cline: return "Cline"
        }
    }


    var accentColor: Color {
        switch self {
        case .claude:
            return Color(red: 0.88, green: 0.44, blue: 0.33)
        case .codex:
            return Color(red: 0.10, green: 0.68, blue: 0.52)
        case .agy:
            return Color(red: 0.40, green: 0.55, blue: 0.98)
        case .cline:
            return Color(red: 0.96, green: 0.65, blue: 0.16)
        }
    }
}
