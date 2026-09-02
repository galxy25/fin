import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformColor = UIColor
#endif

struct AppTheme: Codable, Equatable {
    var backgroundHex: String
    var foregroundHex: String

    static let `default` = AppTheme(backgroundHex: "#000000", foregroundHex: "#00FF00")

    var backgroundColor: Color { Color(hex: backgroundHex) }
    var foregroundColor: Color { Color(hex: foregroundHex) }
    var backgroundPlatformColor: PlatformColor { PlatformColor(hex: backgroundHex) }
    var foregroundPlatformColor: PlatformColor { PlatformColor(hex: foregroundHex) }
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
