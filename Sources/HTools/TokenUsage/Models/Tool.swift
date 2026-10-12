import SwiftUI

enum Tool: String, CaseIterable, Identifiable, Codable {
    case claude = "Claude Code"
    case codex = "Codex"
    case agy = "agy"
    case pi = "pi"
    case zcode = "ZCode"
    case stepcode = "StepCode"

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .agy: return "agy"
        case .pi: return "pi"
        case .zcode: return "ZCode"
        case .stepcode: return "StepCode"
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
        case .pi:
            return Color(red: 0.65, green: 0.42, blue: 0.95)
        case .zcode:
            return Color(red: 0.16, green: 0.62, blue: 0.95)
        case .stepcode:
            return Color(red: 0.96, green: 0.65, blue: 0.16)
        }
    }
}
