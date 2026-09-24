import Foundation

/// Remote Desktop (docs/VNC.md, "Phase 1, as built"): the whole screen of a site, viewed
/// and driven from the Fin app — the full-desktop sibling of Remote Browser.
///
/// It speaks Remote Browser's wire protocol unchanged (`RemoteBrowserProtocol.Frame` out,
/// `RemoteBrowserProtocol.Input` in), not RFB. The app already renders JPEG frames and
/// sends normalized taps, scrolls and text on every platform, iPhone included; RFB would
/// have meant an RFB server in the daemon AND a VNC client in the app, for the same
/// picture. What differs is only where frames come from (ScreenCaptureKit instead of
/// Chrome's screencast) and where input goes (CGEvent instead of CDP) — and the second
/// half is this file: which system events one input becomes, pure so it is tested.
public enum RemoteDesktopProtocol {
    /// One synthesized system event. Coordinates are GLOBAL display points (CGEvent's
    /// space: origin at the main display's top-left, y down), already resolved from the
    /// normalized input against the captured display's bounds.
    public enum Event: Equatable {
        case mouseMove(x: Double, y: Double)
        case mouseDown(x: Double, y: Double)
        case mouseUp(x: Double, y: Double)
        /// Pixel deltas in CGEvent's wheel convention: positive `dy` scrolls content
        /// DOWN (reveals what's above) — the opposite of CDP's deltaY.
        case scroll(dx: Int32, dy: Int32)
        /// Typed text, delivered as unicode strings rather than key codes so any
        /// keyboard layout, emoji or password character arrives as typed.
        case text(String)
        case key(virtualKeyCode: UInt16, modifiers: [RemoteBrowserProtocol.Modifier])
    }

    /// CGEvent's unicode payload is per event and silently truncated past 20 UTF-16
    /// units, so longer text is split. Never splits a surrogate pair.
    public static let maxUnicodeChunk = 20

    /// macOS virtual key codes (HIToolbox `kVK_*`), fixed across layouts.
    public static func virtualKeyCode(for key: RemoteBrowserProtocol.SpecialKey) -> UInt16 {
        switch key {
        case .enter: return 36
        case .tab: return 48
        case .backspace: return 51
        case .escape: return 53
        case .arrowLeft: return 123
        case .arrowRight: return 124
        case .arrowDown: return 125
        case .arrowUp: return 126
        case .home: return 115
        case .end: return 119
        case .pageUp: return 116
        case .pageDown: return 121
        case .forwardDelete: return 117
        case .space: return 49
        case .f11: return 103   // kVK_F11
        case .digit5: return 23 // kVK_ANSI_5
        }
    }

    /// `display` is the captured display's rect in global points. Navigation and tab
    /// selection are browser concepts with no desktop meaning, so they map to nothing.
    public static func events(for input: RemoteBrowserProtocol.Input, display: CGRectLike) -> [Event] {
        func point(_ x: Double, _ y: Double) -> (Double, Double) {
            (display.x + x * display.width, display.y + y * display.height)
        }
        switch input {
        case .tap(let x, let y):
            let (px, py) = point(x, y)
            return [.mouseMove(x: px, y: py), .mouseDown(x: px, y: py), .mouseUp(x: px, y: py)]
        case .scroll(let x, let y, let deltaX, let deltaY):
            let (px, py) = point(x, y)
            // The pointer goes where the finger is first: macOS scrolls whatever is
            // under the cursor, not whatever has focus.
            return [.mouseMove(x: px, y: py), .scroll(dx: wheel(-deltaX), dy: wheel(-deltaY))]
        case .text(let text):
            return unicodeChunks(text).map(Event.text)
        case .key(let key, let modifiers):
            return [.key(virtualKeyCode: virtualKeyCode(for: key), modifiers: modifiers)]
        // selectDisplay is consumed upstream by DesktopRelayClient before it reaches
        // here — see its `handle`, the same shape as BrowserRelayClient's selectTab.
        case .navigate, .selectTab, .selectDisplay:
            return []
        }
    }

    private static func wheel(_ value: Double) -> Int32 {
        Int32(max(Double(Int32.min), min(Double(Int32.max), value.rounded())))
    }

    static func unicodeChunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for character in text {
            if current.utf16.count + character.utf16.count > maxUnicodeChunk, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// "Display 1 (2560x1440)" / "Display 2 \u2014 secondary (1920x1080)": no AppKit
    /// dependency for a friendlier name (`NSScreen.localizedName` would need one), so
    /// the resolution is what tells two displays apart in the picker.
    public static func displayLabel(index: Int, width: Int, height: Int, isMain: Bool) -> String {
        "Display \(index)\(isMain ? "" : " \u{2014} secondary") (\(width)x\(height))"
    }

    /// The captured frame's size: the display's size in points, scaled down to fit
    /// `maxWidth` — points, not retina pixels, because a phone showing a 3024-wide
    /// capture gains nothing but four times the bytes through the relay.
    public static func captureSize(displayWidth: Double, displayHeight: Double, maxWidth: Double) -> (width: Int, height: Int) {
        guard displayWidth > 0, displayHeight > 0 else { return (0, 0) }
        let scale = min(1, maxWidth / displayWidth)
        return (Int((displayWidth * scale).rounded()), Int((displayHeight * scale).rounded()))
    }
}

/// A rect without CoreGraphics, so FinAgentCore stays buildable on Linux.
public struct CGRectLike: Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}
