import SwiftUI

enum ClipboardTheme {
    static let accent = Color(red: 0.08, green: 0.60, blue: 0.46)
    static let accentDeep = Color(red: 0.04, green: 0.36, blue: 0.26)
    static let accentSoft = Color(red: 0.88, green: 0.96, blue: 0.93)

    static let accentGradient = LinearGradient(
        colors: [
            Color(red: 0.10, green: 0.66, blue: 0.50),
            Color(red: 0.05, green: 0.48, blue: 0.36)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let ink = Color(red: 0.12, green: 0.15, blue: 0.17)
    static let inkSecondary = Color(red: 0.40, green: 0.45, blue: 0.48)
    static let inkTertiary = Color(red: 0.60, green: 0.65, blue: 0.68)

    // 兼容别名
    static let mint = accent
    static let mintDeep = accentDeep
    static let mintSoft = accentSoft
    static let seafoam = Color(red: 0.75, green: 0.91, blue: 0.86)
}
