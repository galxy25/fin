// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
import Foundation

/// The wire protocol for Remote Browser (docs/REMOTE-BROWSER.md): the Fin app views and
/// drives ONE browser on a site — the same browser Claude's Playwright is driving there —
/// so Levi can do the parts an agent can't: type a password, approve 2FA, clear a
/// captcha, then hand the signed-in browser back.
///
/// Lives in FinAgentCore because both ends compile it: the daemon encodes frames and
/// decodes input, the app does the reverse. One definition means the two sides cannot
/// drift on a field name — the failure mode a hand-maintained pair of encoders invites.
///
/// Rides the terminal relay UNCHANGED. relay.py forwards whole frames verbatim, routing
/// only on `action` (`output` site→app, `input` app→site) and never inspecting anything
/// else, so browser traffic is just those two actions with a `kind` the relay ignores.
/// No relay redeploy, no new relay action, and the relay stays payload-agnostic.
public enum RemoteBrowserProtocol {
    // MARK: - Kinds

    /// Site → app: one screencast frame.
    public static let frameKind = "browser-frame"
    /// Site → app: the open tabs, and which one is being shown.
    public static let tabsKind = "browser-tabs"
    /// Remote Desktop's sibling of `tabsKind` (docs/VNC.md, "choose displays"): which
    /// physical display is being captured, and what else is available.
    public static let displaysKind = "desktop-displays"
    /// App → site: one input event.
    public static let inputKind = "browser-input"

    /// The relay's frame ceiling is 256 KiB (`MAX_FRAME_BYTES` in relay.py, and the
    /// websocket `max_size` it serves with). A frame over it doesn't just fail — the
    /// relay CLOSES THE WHOLE SESSION ("frame too large"). So the daemon drops any frame
    /// whose base64 exceeds this budget, with headroom for the JSON envelope, rather
    /// than let one busy page kill the session. Dropped, not queued: the next frame is
    /// a complete picture of the page anyway, so nothing is lost but a moment.
    public static let maxFrameBase64Bytes = 200 * 1024

    // MARK: - Frames (site → app)

    public struct Frame: Equatable, Sendable {
        /// JPEG, base64 — the encoding CDP's `Page.screencastFrame` already delivers.
        public var jpegBase64: String
        /// The page viewport in CSS pixels. Input arrives normalized (0…1) and is scaled
        /// by these on the site, so the app never needs to know the device scale factor
        /// or what the screencast downsampled to.
        public var width: Double
        public var height: Double
        public var url: String?
        public var title: String?

        public init(jpegBase64: String, width: Double, height: Double, url: String? = nil, title: String? = nil) {
            self.jpegBase64 = jpegBase64
            self.width = width
            self.height = height
            self.url = url
            self.title = title
        }

        public func relayFrame(sessionId: String) -> [String: Any] {
            var frame: [String: Any] = [
                "action": "output", "sessionId": sessionId, "kind": RemoteBrowserProtocol.frameKind,
                "data": jpegBase64, "width": width, "height": height,
            ]
            if let url { frame["url"] = url }
            if let title { frame["title"] = title }
            return frame
        }

        public init?(relayFrame object: [String: Any]) {
            guard object["kind"] as? String == RemoteBrowserProtocol.frameKind,
                  let data = object["data"] as? String,
                  let width = (object["width"] as? NSNumber)?.doubleValue,
                  let height = (object["height"] as? NSNumber)?.doubleValue,
                  width > 0, height > 0
            else { return nil }
            self.init(
                jpegBase64: data, width: width, height: height,
                url: object["url"] as? String, title: object["title"] as? String
            )
        }
    }

    public struct Tab: Equatable, Sendable {
        public var id: String
        public var title: String
        public var url: String
        public init(id: String, title: String, url: String) {
            self.id = id
            self.title = title
            self.url = url
        }
    }

    public static func tabsFrame(sessionId: String, tabs: [Tab], selected: String?) -> [String: Any] {
        var frame: [String: Any] = [
            "action": "output", "sessionId": sessionId, "kind": tabsKind,
            "tabs": tabs.map { ["id": $0.id, "title": $0.title, "url": $0.url] },
        ]
        if let selected { frame["selected"] = selected }
        return frame
    }

    public static func tabs(fromRelayFrame object: [String: Any]) -> (tabs: [Tab], selected: String?)? {
        guard object["kind"] as? String == tabsKind, let raw = object["tabs"] as? [[String: Any]] else { return nil }
        let tabs = raw.compactMap { entry -> Tab? in
            guard let id = entry["id"] as? String else { return nil }
            return Tab(id: id, title: entry["title"] as? String ?? "", url: entry["url"] as? String ?? "")
        }
        return (tabs, object["selected"] as? String)
    }

    /// One physical display a Remote Desktop site can capture — the desktop mode
    /// sibling of `Tab`. `id` is the display's `CGDirectDisplayID` as a string (opaque
    /// to the app; only the daemon interprets it).
    public struct Display: Equatable, Sendable {
        public var id: String
        public var label: String
        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    public static func displaysFrame(sessionId: String, displays: [Display], selected: String?) -> [String: Any] {
        var frame: [String: Any] = [
            "action": "output", "sessionId": sessionId, "kind": displaysKind,
            "displays": displays.map { ["id": $0.id, "label": $0.label] },
        ]
        if let selected { frame["selected"] = selected }
        return frame
    }

    public static func displays(fromRelayFrame object: [String: Any]) -> (displays: [Display], selected: String?)? {
        guard object["kind"] as? String == displaysKind, let raw = object["displays"] as? [[String: Any]] else { return nil }
        let displays = raw.compactMap { entry -> Display? in
            guard let id = entry["id"] as? String else { return nil }
            return Display(id: id, label: entry["label"] as? String ?? "Display")
        }
        return (displays, object["selected"] as? String)
    }

    // MARK: - Input (app → site)

    public enum SpecialKey: String, CaseIterable, Sendable {
        case enter, tab, backspace, escape, arrowUp, arrowDown, arrowLeft, arrowRight
        case home, end, pageUp, pageDown, forwardDelete, space
        /// Show Desktop's own shortcut (macOS default: bare F11 — no modifier).
        case f11
        /// Only ever meant to ride WITH modifiers (Cmd+Shift+5 for Screenshot); not a
        /// general "type a 5" key — that goes through `.text`.
        case digit5
    }

    /// A modifier held while a key is sent — the carousel toolbar's Ctrl/Opt/Cmd/Shift
    /// latches (docs/VNC.md): tap one to arm it, then the next key press carries it,
    /// mirroring the terminal's existing Ctrl-latch (`FinTerminalView.ctrlArmed`) so the
    /// gesture is one Levi already knows. Meaningful in both modes: Cmd+A/C/V in a
    /// browser field, Cmd+Tab or Ctrl+click on a desktop.
    public enum Modifier: String, CaseIterable, Sendable {
        case shift, control, option, command
    }

    public enum Input: Equatable, Sendable {
        /// A click at a point, normalized to the frame (0…1 on each axis) so the app's
        /// view size, letterboxing and the device scale factor never cross the wire.
        case tap(x: Double, y: Double)
        /// A wheel scroll at a normalized point, deltas in CSS pixels.
        case scroll(x: Double, y: Double, deltaX: Double, deltaY: Double)
        /// Text typed into whatever has focus. `Input.insertText`, not per-character key
        /// events: a password pasted from a manager arrives whole and exactly, with none
        /// of the keymap guessing synthetic keystrokes need.
        case text(String)
        case key(SpecialKey, modifiers: [Modifier] = [])
        case navigate(String)
        case selectTab(String)
        /// Remote Desktop only (docs/VNC.md, "choose displays"): capture a different
        /// physical display. Meaningless to a browser session — `Display.id`.
        case selectDisplay(String)
    }

    public static func inputFrame(sessionId: String, input: Input) -> [String: Any] {
        ["action": "input", "sessionId": sessionId, "kind": inputKind, "event": encode(input)]
    }

    static func encode(_ input: Input) -> [String: Any] {
        switch input {
        case .tap(let x, let y): return ["type": "tap", "x": x, "y": y]
        case .scroll(let x, let y, let dx, let dy): return ["type": "scroll", "x": x, "y": y, "dx": dx, "dy": dy]
        case .text(let text): return ["type": "text", "text": text]
        case .key(let key, let modifiers):
            var event: [String: Any] = ["type": "key", "key": key.rawValue]
            if !modifiers.isEmpty { event["modifiers"] = modifiers.map(\.rawValue) }
            return event
        case .navigate(let url): return ["type": "navigate", "url": url]
        case .selectTab(let id): return ["type": "selectTab", "id": id]
        case .selectDisplay(let id): return ["type": "selectDisplay", "id": id]
        }
    }

    public static func input(fromRelayFrame object: [String: Any]) -> Input? {
        guard object["kind"] as? String == inputKind, let event = object["event"] as? [String: Any],
              let type = event["type"] as? String else { return nil }
        func number(_ key: String) -> Double? { (event[key] as? NSNumber)?.doubleValue }
        switch type {
        case "tap":
            guard let x = number("x"), let y = number("y") else { return nil }
            return .tap(x: clamp(x), y: clamp(y))
        case "scroll":
            guard let x = number("x"), let y = number("y") else { return nil }
            return .scroll(x: clamp(x), y: clamp(y), deltaX: number("dx") ?? 0, deltaY: number("dy") ?? 0)
        case "text":
            guard let text = event["text"] as? String, !text.isEmpty else { return nil }
            return .text(text)
        case "key":
            guard let raw = event["key"] as? String, let key = SpecialKey(rawValue: raw) else { return nil }
            let modifiers = (event["modifiers"] as? [String] ?? []).compactMap(Modifier.init(rawValue:))
            return .key(key, modifiers: modifiers)
        case "navigate":
            guard let url = event["url"] as? String, !url.isEmpty else { return nil }
            return .navigate(url)
        case "selectTab":
            guard let id = event["id"] as? String, !id.isEmpty else { return nil }
            return .selectTab(id)
        case "selectDisplay":
            guard let id = event["id"] as? String, !id.isEmpty else { return nil }
            return .selectDisplay(id)
        default:
            return nil
        }
    }

    /// Normalized coordinates are clamped, never trusted: a tap computed from a stale
    /// frame size can land a hair outside 0…1, and a click just past the viewport edge
    /// is a click on nothing rather than an error.
    static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

    // MARK: - CDP translation (site side)

    /// One Chrome DevTools Protocol command: a method and its params.
    public struct CDPCommand: Equatable {
        public var method: String
        public var params: [String: AnyHashable]
        public init(_ method: String, _ params: [String: AnyHashable] = [:]) {
            self.method = method
            self.params = params
        }
    }

    /// The CDP commands one input event becomes, given the viewport it was aimed at.
    /// Pure, so the translation — the part most likely to be subtly wrong (a missing
    /// `text` on Enter means forms don't submit; a click without both press AND release
    /// is no click at all) — is pinned by tests rather than discovered in a live browser.
    /// `.selectTab` returns nothing: switching tabs is a target change, not a command
    /// sent to the current page.
    public static func cdpCommands(for input: Input, viewportWidth: Double, viewportHeight: Double) -> [CDPCommand] {
        switch input {
        case .tap(let x, let y):
            let px = x * viewportWidth, py = y * viewportHeight
            return [
                CDPCommand("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": px, "y": py]),
                CDPCommand("Input.dispatchMouseEvent", ["type": "mousePressed", "x": px, "y": py, "button": "left", "clickCount": 1]),
                CDPCommand("Input.dispatchMouseEvent", ["type": "mouseReleased", "x": px, "y": py, "button": "left", "clickCount": 1]),
            ]
        case .scroll(let x, let y, let dx, let dy):
            return [CDPCommand("Input.dispatchMouseEvent", [
                "type": "mouseWheel", "x": x * viewportWidth, "y": y * viewportHeight, "deltaX": dx, "deltaY": dy,
            ])]
        case .text(let text):
            return [CDPCommand("Input.insertText", ["text": text])]
        case .key(let key, let modifiers):
            let spec = keySpec(key)
            let mask = cdpModifierMask(modifiers)
            var down: [String: AnyHashable] = [
                "type": "keyDown", "key": spec.key, "code": spec.code,
                "windowsVirtualKeyCode": spec.keyCode, "nativeVirtualKeyCode": spec.keyCode,
            ]
            // Enter needs `text` on keyDown or Chrome treats it as a bare key with no
            // character — the field sees the key but the form never submits. A modified
            // Enter (rare) skips it: Chrome would otherwise also submit a form on Cmd+Enter.
            if let text = spec.text, modifiers.isEmpty { down["text"] = text }
            if mask != 0 { down["modifiers"] = mask }
            var up: [String: AnyHashable] = [
                "type": "keyUp", "key": spec.key, "code": spec.code,
                "windowsVirtualKeyCode": spec.keyCode, "nativeVirtualKeyCode": spec.keyCode,
            ]
            if mask != 0 { up["modifiers"] = mask }
            return [CDPCommand("Input.dispatchKeyEvent", down), CDPCommand("Input.dispatchKeyEvent", up)]
        case .navigate(let url):
            return [CDPCommand("Page.navigate", ["url": normalizedURL(url)])]
        case .selectTab, .selectDisplay:
            return []
        }
    }

    static func keySpec(_ key: SpecialKey) -> (key: String, code: String, keyCode: Int, text: String?) {
        switch key {
        case .enter: return ("Enter", "Enter", 13, "\r")
        case .tab: return ("Tab", "Tab", 9, nil)
        case .backspace: return ("Backspace", "Backspace", 8, nil)
        case .escape: return ("Escape", "Escape", 27, nil)
        case .arrowUp: return ("ArrowUp", "ArrowUp", 38, nil)
        case .arrowDown: return ("ArrowDown", "ArrowDown", 40, nil)
        case .arrowLeft: return ("ArrowLeft", "ArrowLeft", 37, nil)
        case .arrowRight: return ("ArrowRight", "ArrowRight", 39, nil)
        case .home: return ("Home", "Home", 36, nil)
        case .end: return ("End", "End", 35, nil)
        case .pageUp: return ("PageUp", "PageUp", 33, nil)
        case .pageDown: return ("PageDown", "PageDown", 34, nil)
        case .forwardDelete: return ("Delete", "Delete", 46, nil)
        case .space: return (" ", "Space", 32, " ")
        case .f11: return ("F11", "F11", 122, nil)
        case .digit5: return ("5", "Digit5", 53, nil)
        }
    }

    /// CDP's `Input.dispatchKeyEvent` modifier bitmask: Alt 1, Ctrl 2, Meta/Cmd 4, Shift 8.
    static func cdpModifierMask(_ modifiers: [Modifier]) -> Int {
        modifiers.reduce(0) { mask, modifier in
            switch modifier {
            case .shift: return mask | 8
            case .control: return mask | 2
            case .option: return mask | 1
            case .command: return mask | 4
            }
        }
    }

    /// "github.com" → "https://github.com". A bare host typed on a phone keyboard is the
    /// common case; Chrome's own omnibox does the same.
    public static func normalizedURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://"#, options: .regularExpression) != nil { return trimmed }
        if trimmed.hasPrefix("about:") { return trimmed }
        return "https://" + trimmed
    }

    // MARK: - Tab selection (site side)

    /// One entry of Chrome's `GET /json/list`.
    public struct Target: Equatable, Sendable {
        public var id: String
        public var type: String
        public var title: String
        public var url: String
        public var webSocketDebuggerUrl: String?
        public init(id: String, type: String, title: String, url: String, webSocketDebuggerUrl: String?) {
            self.id = id
            self.type = type
            self.title = title
            self.url = url
            self.webSocketDebuggerUrl = webSocketDebuggerUrl
        }
    }

    /// The tabs worth showing: real pages, not DevTools windows, extension background
    /// pages, or service workers — Chrome lists all of those as targets too.
    public static func viewableTabs(_ targets: [Target]) -> [Target] {
        targets.filter { target in
            target.type == "page"
                && target.webSocketDebuggerUrl != nil
                && !target.url.hasPrefix("devtools://")
                && !target.url.hasPrefix("chrome-extension://")
        }
    }

    /// Which tab to show: the one asked for if it still exists, else the first — Chrome
    /// orders `/json/list` most-recently-active first, which is the tab Claude was just
    /// working in and therefore the one a sign-in prompt is sitting in.
    public static func pickTab(_ targets: [Target], preferring preferred: String?) -> Target? {
        let tabs = viewableTabs(targets)
        if let preferred, let match = tabs.first(where: { $0.id == preferred }) { return match }
        return tabs.first
    }

    public static func targets(fromJSONList data: Data) -> [Target] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let id = entry["id"] as? String, let type = entry["type"] as? String else { return nil }
            return Target(
                id: id, type: type, title: entry["title"] as? String ?? "", url: entry["url"] as? String ?? "",
                webSocketDebuggerUrl: entry["webSocketDebuggerUrl"] as? String
            )
        }
    }
}

// MARK: - Finding a browser to launch

extension RemoteBrowserProtocol {
    /// Where to look for a browser, best first. Real Google Chrome leads because Google's
    /// own sign-in is least suspicious of it; Playwright's bundled browser is the
    /// fallback — the work laptop (2026-09-23) has no Chrome in /Applications at all, only
    /// what `npx playwright install` put in its cache, and that browser launched WITHOUT
    /// Playwright's automation flags is an ordinary browser for signing in.
    ///
    /// Pure over `home` and a directory lister so the order is tested directly.
    public static func browserCandidates(home: String, listDirectory: (String) -> [String]) -> [String] {
        var paths = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            home + "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
        ]
        let cache = home + "/Library/Caches/ms-playwright"
        // chromium-1181 before chromium-1169: newest install first. Numeric, not
        // lexical, so chromium-999 never outranks chromium-1000.
        let revisions = listDirectory(cache)
            .filter { $0.hasPrefix("chromium-") }
            .sorted { (Int($0.dropFirst("chromium-".count)) ?? 0) > (Int($1.dropFirst("chromium-".count)) ?? 0) }
        for revision in revisions {
            let root = cache + "/" + revision
            // Playwright has shipped both layouts; accept either.
            paths.append(root + "/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing")
            paths.append(root + "/chrome-mac/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing")
            paths.append(root + "/chrome-mac/Chromium.app/Contents/MacOS/Chromium")
        }
        return paths
    }

    /// The configured path when it is set (an explicit choice is never second-guessed),
    /// else the first candidate that is actually executable here.
    public static func findBrowser(
        configured: String?, home: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        listDirectory: (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
    ) -> String? {
        if let configured { return isExecutable(configured) ? configured : nil }
        return browserCandidates(home: home, listDirectory: listDirectory).first(where: isExecutable)
    }
}
