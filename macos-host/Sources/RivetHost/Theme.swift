import SwiftUI

/// Keyward design tokens. Warm vault identity on the family's layered-gray
/// neutral base (same token structure as the taskly host): saturated color
/// lives on glyphs and primary buttons only — selection and hover are quiet
/// fills; borders never change color with state.
enum Palette {
    static let accentLight = Color(hex: 0xC15F3C)
    static let accentDark = Color(hex: 0xD08A6E)

    static let okLight = Color(hex: 0x2E7D32)
    static let okDark = Color(hex: 0x81C784)
    static let warnLight = Color(hex: 0xB26A00)
    static let warnDark = Color(hex: 0xFFB74D)
    static let neutralLight = Color(hex: 0x8E8E93)
    static let neutralDark = Color(hex: 0x98989E)

    // Light theme (warm paper, aligned with the product site tokens)
    static let lightBackground = Color(hex: 0xFAF7F2)
    static let lightSidebar = Color(hex: 0xF3EEE6)
    static let lightSurface = Color(hex: 0xFFFFFF)
    static let lightDivider = Color(hex: 0xE8E2D9)
    static let lightOnSurface = Color(hex: 0x241F1B)
    static let lightSecondaryText = Color(hex: 0x6B6660)
    static let lightTertiaryText = Color(hex: 0xA8A099)
    static let lightSelection = Color(hex: 0xC15F3C, alpha: 0.10)
    static let lightHover = Color(hex: 0xC15F3C, alpha: 0.06)
    static let lightBadgeBackground = Color(hex: 0xF0EBE2)

    // Dark theme (layered warm grays)
    static let darkBackground = Color(hex: 0x1B1A18)
    static let darkSidebar = Color(hex: 0x24221F)
    static let darkSurface = Color(hex: 0x2E2B27)
    static let darkDivider = Color(hex: 0x3A362F)
    static let darkOnSurface = Color(hex: 0xECE9E2)
    static let darkSecondaryText = Color(hex: 0xA6A099)
    static let darkTertiaryText = Color(hex: 0x6B6660)
    static let darkSelection = Color(hex: 0xD08A6E, alpha: 0.16)
    static let darkHover = Color(hex: 0xD08A6E, alpha: 0.10)
    static let darkBadgeBackground = Color(hex: 0x3A362F)

    // Geometry
    static let sidebarWidth: CGFloat = 280
    static let statusHeight: CGFloat = 28
    static let cardRadius: CGFloat = 8
}

/// View-model theme snapshot. `isDark` mirrors the effective appearance so
/// the custom palette tracks macOS live; both themes are verified states.
struct ThemeState {
    let isDark: Bool

    var background: Color { isDark ? Palette.darkBackground : Palette.lightBackground }
    var sidebar: Color { isDark ? Palette.darkSidebar : Palette.lightSidebar }
    var surface: Color { isDark ? Palette.darkSurface : Palette.lightSurface }
    var divider: Color { isDark ? Palette.darkDivider : Palette.lightDivider }
    var onSurface: Color { isDark ? Palette.darkOnSurface : Palette.lightOnSurface }
    var secondaryText: Color { isDark ? Palette.darkSecondaryText : Palette.lightSecondaryText }
    var tertiaryText: Color { isDark ? Palette.darkTertiaryText : Palette.lightTertiaryText }
    var selection: Color { isDark ? Palette.darkSelection : Palette.lightSelection }
    var hover: Color { isDark ? Palette.darkHover : Palette.lightHover }
    var badgeBackground: Color { isDark ? Palette.darkBadgeBackground : Palette.lightBadgeBackground }
    var accent: Color { isDark ? Palette.accentDark : Palette.accentLight }
    var ok: Color { isDark ? Palette.okDark : Palette.okLight }
    var warn: Color { isDark ? Palette.warnDark : Palette.warnLight }
    var neutral: Color { isDark ? Palette.neutralDark : Palette.neutralLight }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha)
    }
}
