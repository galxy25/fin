import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#endif

struct AppTheme: Codable, Equatable {
    var backgroundHex: String
    var foregroundHex: String
    /// Terminal font size in points.
    var fontSize: Double = AppTheme.defaultFontSize

    static let `default` = AppTheme(backgroundHex: "#000000", foregroundHex: "#00FF00")

    /// SwiftTerm's own default: the system font size on macOS, 12pt elsewhere.
    #if os(macOS)
    static let defaultFontSize: Double = Double(NSFont.systemFontSize)
    #else
    static let defaultFontSize: Double = 12
    #endif
    static let fontSizeRange: ClosedRange<Double> = 8...32

    /// Markdown body text defaults to the platform's body size (13pt on macOS, 17pt elsewhere).
    #if os(macOS)
    static let defaultMarkdownFontSize: Double = 13
    #else
    static let defaultMarkdownFontSize: Double = 17
    #endif

    var terminalFont: PlatformFont {
        .monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
    }

    var backgroundColor: Color { Color(hex: backgroundHex) }
    var foregroundColor: Color { Color(hex: foregroundHex) }
    var backgroundPlatformColor: PlatformColor { PlatformColor(hex: backgroundHex) }
    var foregroundPlatformColor: PlatformColor { PlatformColor(hex: foregroundHex) }
}

/// Which surface a theme applies to. The terminal and the markdown reader are
/// themed independently, each under its own set of `@AppStorage` keys.
enum ThemeScope: CaseIterable {
    case terminal
    case markdown

    var title: String {
        switch self {
        case .terminal: "Terminal Theme"
        case .markdown: "Markdown Theme"
        }
    }

    // The terminal keeps the original unprefixed keys so existing settings carry over.
    var backgroundKey: String { self == .terminal ? "themeBackgroundHex" : "markdownThemeBackgroundHex" }
    var foregroundKey: String { self == .terminal ? "themeForegroundHex" : "markdownThemeForegroundHex" }
    var fontSizeKey: String { self == .terminal ? "themeFontSize" : "markdownThemeFontSize" }
    /// Per-device, never synced: whether this scope follows the account (`ThemeSync`).
    var syncEnabledKey: String { self == .terminal ? "themeSyncEnabled" : "markdownThemeSyncEnabled" }
    var syncedKeys: [String] { [backgroundKey, foregroundKey, fontSizeKey] }

    // Markdown used to share the terminal's colors, so until it's customized on
    // its own it starts from whatever the terminal is set to.
    var defaultBackgroundHex: String {
        self == .terminal ? AppTheme.default.backgroundHex
            : UserDefaults.standard.string(forKey: ThemeScope.terminal.backgroundKey) ?? AppTheme.default.backgroundHex
    }
    var defaultForegroundHex: String {
        self == .terminal ? AppTheme.default.foregroundHex
            : UserDefaults.standard.string(forKey: ThemeScope.terminal.foregroundKey) ?? AppTheme.default.foregroundHex
    }

    var defaultFontSize: Double {
        self == .terminal ? AppTheme.defaultFontSize : AppTheme.defaultMarkdownFontSize
    }
}

extension PlatformColor {
    convenience init(hex: String) {
        var sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized.removeAll { $0 == "#" }
        var value: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&value)

        let r, g, b: UInt64
        switch sanitized.count {
        case 6:
            r = (value >> 16) & 0xFF
            g = (value >> 8) & 0xFF
            b = value & 0xFF
        default:
            r = 0
            g = 0
            b = 0
        }

        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(macOS)
        (usingColorSpace(.deviceRGB) ?? self).getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        return String(
            format: "#%02X%02X%02X",
            Int((r * 255).rounded()),
            Int((g * 255).rounded()),
            Int((b * 255).rounded())
        )
    }
}

extension SwiftUI.Color {
    init(hex: String) {
        #if os(macOS)
        self.init(nsColor: PlatformColor(hex: hex))
        #else
        self.init(uiColor: PlatformColor(hex: hex))
        #endif
    }

    func toHexString() -> String {
        PlatformColor(self).hexString
    }
}
