import SwiftUI

// MARK: - ClipSpark Design Tokens
// Every color / spacing / radius / type size lives here. No hardcoded values elsewhere.

public extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

public enum CSTheme {
    // Backgrounds
    public static let bg          = Color(hex: 0x0B0B0F)
    public static let surface     = Color(hex: 0x16161D)
    public static let surfaceHigh = Color(hex: 0x1E1E27)
    public static let hairline    = Color(hex: 0x2A2A33)
    public static let textPrimary = Color(hex: 0xFFFFFF)
    public static let textSecondary = Color(hex: 0x9B9BA5)

    // Accents
    public static let accent = Color(hex: 0x00E0C6)          // electric cyan-teal
    public static let accentGradient = LinearGradient(
        colors: [Color(hex: 0x00E0C6), accentViolet],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    public static let selection = Color(hex: 0xFFD60A)       // selected clip outline
    public static let accentViolet = Color(hex: 0x7C5CFF)    // gradient tail / seed color

    /// Card thumbnail seed palette for drafts & templates.
    public static let seedPalette: [Color] = [accent, accentViolet, selection]

    // Semantic
    public static let danger  = Color(hex: 0xFF453A)
    public static let success = Color(hex: 0x32D74B)
}

public enum CSSpacing {
    public static let xs: CGFloat = 4
    public static let s:  CGFloat = 8
    public static let m:  CGFloat = 12
    public static let l:  CGFloat = 16
}

public enum CSRadius {
    public static let card: CGFloat = 14
    public static let chip: CGFloat = 22
    public static let sheet: CGFloat = 20
}

public enum CSType {
    public static let title    = Font.system(size: 17, weight: .semibold)
    public static let body     = Font.system(size: 14, weight: .regular)
    public static let chip     = Font.system(size: 12, weight: .medium)
    public static let timecode = Font.system(size: 11, weight: .regular, design: .monospaced)
}

public enum CSMotion {
    public static let fast: Double = 0.15
    public static let standard: Double = 0.22
    public static let easeOut: Animation = .easeOut(duration: CSMotion.standard)
    public static let fastOut: Animation = .easeOut(duration: CSMotion.fast)
}
