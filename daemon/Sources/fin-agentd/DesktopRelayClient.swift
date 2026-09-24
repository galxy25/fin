#if os(macOS)
import Foundation
import FinAgentCore
import ScreenCaptureKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ApplicationServices

/// Remote Desktop (docs/VNC.md, "Phase 1, as built"): this Mac's main display, relayed to
/// the Fin app, with taps and typing played back as real mouse and keyboard events.
///
/// Remote Browser's pipeline with a different source. Frames are captured with
/// ScreenCaptureKit (the Screen Recording grant) and sent as `RemoteBrowserProtocol`
/// frames; input arrives as `RemoteBrowserProtocol.Input` and becomes CGEvents (the
/// Accessibility grant) via `RemoteDesktopProtocol.events`. Without Accessibility the
/// session still opens — view-only — and says so once in the audit log.
///
/// Why not an RFB (VNC) server: the work laptop's MDM keeps macOS Screen Sharing off,
/// so there is no Apple server to proxy to, and writing our own RFB server would also
/// need a VNC client in the app — for the same JPEG the app already knows how to show.
///
/// Same dial / self-heal / idle shape as `BrowserRelayClient` and `TerminalRelayClient`
/// (see the former for why these stay siblings rather than one generalized client).
@MainActor
public final class DesktopRelayClient {
    static let idleTimeout: TimeInterval = 15 * 60
    static let connectAttempts = 45
    static let dialFailuresBeforeSelfHeal = 2
    /// ~4 fps. A remote desktop for signing in and unsticking things, not for video; each
    /// capture is also a JPEG encode, and an unchanged screen is skipped before sending.
    static let captureInterval: Duration = .milliseconds(250)
    static let maxCaptureWidth: Double = 1600
    /// Tried in order until the frame fits the relay budget; the last resort shrinks the
    /// capture for subsequent frames instead of sending nothing forever.
    static let jpegQualities: [Double] = [0.55, 0.35, 0.2]

    private let siteID: String
    private let siteToken: String
    private let controlPlaneURL: String?
    private var relaySession: URLSession
    private let audit: (String) -> Void
    private var consecutiveDialFailures = 0

    private final class Session {
        let socket: URLSessionWebSocketTask
        var captureTask: Task<Void, Never>?
        var idleTask: Task<Void, Never>?
        var displayRect = CGRectLike(x: 0, y: 0, width: 0, height: 0)
        var widthCap = DesktopRelayClient.maxCaptureWidth
        var lastFrame: Data?
        var warnedViewOnly = false
        var droppedFrames = 0
        /// nil = main display. Set by `.selectDisplay` ("choose displays" — Levi,
        /// 2026-09-23). Falls back to main if the targeted display disappears.
        var targetDisplayID: CGDirectDisplayID?
        var lastDisplays: [RemoteBrowserProtocol.Display] = []
        var lastSentSelectedDisplay: String?
        // Telemetry (Levi, 2026-09-23): shape only — no captured pixels, no played-back
        // text, ever logged. See BrowserRelayClient.Session for the matching fields.
        let openedAt = Date()
        var framesSent = 0
        var inputCounts: [String: Int] = [:]
        init(socket: URLSessionWebSocketTask) { self.socket = socket }
    }

    private var sessions: [String: Session] = [:]

    public init(siteID: String, siteToken: String, controlPlaneURL: String?, audit: @escaping (String) -> Void) {
        self.siteID = siteID
        self.siteToken = siteToken
        self.controlPlaneURL = controlPlaneURL
        self.relaySession = Self.freshRelaySession()
        self.audit = audit
    }

    private static func freshRelaySession() -> URLSession {
        URLSession(configuration: .default, delegate: RelayPinningDelegate(), delegateQueue: nil)
    }

    // MARK: - Open

    public func open(sessionId: String, relayHost: String, relayPort: Int) {
        audit("[desktop] vnc-open \(sessionId): received (relay=\(relayHost):\(relayPort))")
        guard sessions[sessionId] == nil else {
            audit("[desktop] vnc-open \(sessionId): ignored — already relaying (duplicate command)")
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            // Checked here too, not only in the advertised capability: a grant revoked
            // since the last heartbeat must fail loudly, not stream black frames.
            audit("[desktop] vnc-open \(sessionId): refused — no Screen Recording permission")
            return
        }
        guard let url = URL(string: "wss://\(relayHost):\(relayPort)/") else {
            audit("[desktop] vnc-open \(sessionId): unusable relay address")
            return
        }
        dial(sessionId: sessionId, url: url, attemptsRemaining: Self.connectAttempts)
    }

    private func dial(sessionId: String, url: URL, attemptsRemaining: Int) {
        guard sessions[sessionId] == nil else { return }
        let socket = relaySession.webSocketTask(with: url)
        socket.resume()
        guard let attach = try? JSONSerialization.data(withJSONObject: ["action": "attach", "sessionId": sessionId]) else { return }
        socket.send(.data(attach)) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let error else {
                    self.consecutiveDialFailures = 0
                    self.startRelaying(sessionId: sessionId, socket: socket)
                    return
                }
                socket.cancel(with: .goingAway, reason: nil)
                guard attemptsRemaining > 1 else {
                    self.audit("[desktop] \(sessionId): relay never came up — \(error.localizedDescription.prefix(160))")
                    self.consecutiveDialFailures += 1
                    if self.consecutiveDialFailures >= Self.dialFailuresBeforeSelfHeal {
                        self.audit("[desktop] \(self.consecutiveDialFailures) consecutive dial failures — replacing the relay URLSession")
                        self.relaySession.invalidateAndCancel()
                        self.relaySession = Self.freshRelaySession()
                        self.consecutiveDialFailures = 0
                    }
                    return
                }
                try? await Task.sleep(for: .seconds(2))
                self.dial(sessionId: sessionId, url: url, attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    private func startRelaying(sessionId: String, socket: URLSessionWebSocketTask) {
        guard sessions[sessionId] == nil else {
            socket.cancel(with: .goingAway, reason: nil)
            return
        }
        let session = Session(socket: socket)
        sessions[sessionId] = session
        receiveLoop(sessionId: sessionId)
        armIdleTimeout(sessionId: sessionId)
        session.captureTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.captureOnce(sessionId: sessionId)
                try? await Task.sleep(for: Self.captureInterval)
            }
        }
        audit("[desktop] vnc-open \(sessionId): streaming (input \(AXIsProcessTrusted() ? "enabled" : "OFF — no Accessibility permission, view-only"))")
    }

    // MARK: - Capture

    private func captureOnce(sessionId: String) async {
        guard let session = sessions[sessionId] else { return }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            audit("[desktop] \(sessionId): cannot enumerate displays — \(error.localizedDescription.prefix(160))")
            close(sessionId: sessionId, sendCloseFrame: true)
            return
        }
        // An unplugged targeted display falls back to main on the very next frame
        // rather than freezing on its last picture forever.
        if let targetID = session.targetDisplayID, !content.displays.contains(where: { $0.displayID == targetID }) {
            session.targetDisplayID = nil
            audit("[desktop] \(sessionId): targeted display disappeared — back to the main display")
        }
        guard let display = content.displays.first(where: { $0.displayID == (session.targetDisplayID ?? CGMainDisplayID()) })
            ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
        else { return }
        let bounds = CGDisplayBounds(display.displayID)
        session.displayRect = CGRectLike(x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: bounds.height)
        // "Choose displays" (Levi, 2026-09-23): resent only when the set or the
        // selection changes, the same throttling `sendTabs` uses for browser tabs.
        sendDisplaysIfChanged(sessionId: sessionId, session: session, allDisplays: content.displays, selected: display.displayID)

        let size = RemoteDesktopProtocol.captureSize(
            displayWidth: bounds.width, displayHeight: bounds.height, maxWidth: session.widthCap
        )
        guard size.width > 0 else { return }
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.showsCursor = true
        let filter = SCContentFilter(display: display, excludingWindows: [])
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { return }
        guard sessions[sessionId] != nil else { return }

        var encoded: String?
        for quality in Self.jpegQualities {
            guard let jpeg = Self.jpeg(image, quality: quality) else { return }
            // An unchanged screen is the common case — don't resend the same picture.
            if quality == Self.jpegQualities[0] {
                if jpeg == session.lastFrame { return }
                session.lastFrame = jpeg
            }
            let base64 = jpeg.base64EncodedString()
            if base64.utf8.count <= RemoteBrowserProtocol.maxFrameBase64Bytes {
                encoded = base64
                break
            }
        }
        guard let encoded else {
            // Even the lowest quality is over the relay's budget (a busy, high-detail
            // screen): shrink future captures rather than drop every frame.
            session.droppedFrames += 1
            session.widthCap = max(640, session.widthCap * 0.8)
            audit("[desktop] \(sessionId): frame over budget — capture width now \(Int(session.widthCap))")
            return
        }
        session.framesSent += 1
        let frame = RemoteBrowserProtocol.Frame(
            jpegBase64: encoded, width: bounds.width, height: bounds.height,
            url: nil, title: Host.current().localizedName
        )
        send(sessionId: sessionId, frame: frame.relayFrame(sessionId: sessionId))
    }

    private static func inputTypeName(_ input: RemoteBrowserProtocol.Input) -> String {
        switch input {
        case .tap: return "tap"
        case .scroll: return "scroll"
        case .text: return "text"
        case .key: return "key"
        case .navigate: return "navigate"
        case .selectTab: return "selectTab"
        case .selectDisplay: return "selectDisplay"
        }
    }

    /// Rebuilds the list from the CURRENT enumeration each call — cheap, and it means a
    /// monitor plugged in or unplugged mid-session shows up within one capture tick.
    /// Sent only when the set or the selection actually changed, like `sendTabs`.
    private func sendDisplaysIfChanged(sessionId: String, session: Session, allDisplays: [SCDisplay], selected: CGDirectDisplayID) {
        let sorted = allDisplays.sorted { $0.displayID < $1.displayID }
        let list = sorted.enumerated().map { index, display -> RemoteBrowserProtocol.Display in
            let bounds = CGDisplayBounds(display.displayID)
            let label = RemoteDesktopProtocol.displayLabel(
                index: index + 1, width: Int(bounds.width), height: Int(bounds.height),
                isMain: display.displayID == CGMainDisplayID()
            )
            return RemoteBrowserProtocol.Display(id: String(display.displayID), label: label)
        }
        let selectedID = String(selected)
        guard list != session.lastDisplays || selectedID != session.lastSentSelectedDisplay else { return }
        session.lastDisplays = list
        session.lastSentSelectedDisplay = selectedID
        send(sessionId: sessionId, frame: RemoteBrowserProtocol.displaysFrame(sessionId: sessionId, displays: list, selected: selectedID))
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: - Input

    private func play(_ input: RemoteBrowserProtocol.Input, session: Session, sessionId: String) {
        guard AXIsProcessTrusted() else {
            if !session.warnedViewOnly {
                session.warnedViewOnly = true
                audit("[desktop] \(sessionId): input ignored — no Accessibility permission (view-only)")
            }
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for event in RemoteDesktopProtocol.events(for: input, display: session.displayRect) {
            switch event {
            case .mouseMove(let x, let y):
                CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?
                    .post(tap: .cghidEventTap)
            case .mouseDown(let x, let y):
                CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?
                    .post(tap: .cghidEventTap)
            case .mouseUp(let x, let y):
                CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?
                    .post(tap: .cghidEventTap)
            case .scroll(let dx, let dy):
                CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?
                    .post(tap: .cghidEventTap)
            case .text(let text):
                let units = Array(text.utf16)
                for keyDown in [true, false] {
                    guard let key = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                    key.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    key.post(tap: .cghidEventTap)
                }
            case .key(let code, let modifiers):
                let flags = cgEventFlags(modifiers)
                for keyDown in [true, false] {
                    guard let keyEvent = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: keyDown) else { continue }
                    if !flags.isEmpty { keyEvent.flags = flags }
                    keyEvent.post(tap: .cghidEventTap)
                }
            }
        }
    }

    /// RemoteBrowserProtocol.Modifier -> CGEventFlags, for the carousel toolbar's
    /// Ctrl/Opt/Cmd/Shift latches.
    private func cgEventFlags(_ modifiers: [RemoteBrowserProtocol.Modifier]) -> CGEventFlags {
        modifiers.reduce(into: CGEventFlags()) { flags, modifier in
            switch modifier {
            case .shift: flags.insert(.maskShift)
            case .control: flags.insert(.maskControl)
            case .option: flags.insert(.maskAlternate)
            case .command: flags.insert(.maskCommand)
            }
        }
    }

    // MARK: - Relay socket

    private func receiveLoop(sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        session.socket.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.sessions[sessionId] != nil else { return }
                switch result {
                case .failure(let error):
                    self.audit("[desktop] \(sessionId): socket error — \(error.localizedDescription.prefix(160))")
                    self.close(sessionId: sessionId, sendCloseFrame: false)
                case .success(let message):
                    self.handle(sessionId: sessionId, message: message)
                    self.receiveLoop(sessionId: sessionId)
                }
            }
        }
    }

    private func handle(sessionId: String, message: URLSessionWebSocketTask.Message) {
        guard let session = sessions[sessionId] else { return }
        let data: Data
        switch message {
        case .data(let raw): data = raw
        case .string(let text): data = Data(text.utf8)
        @unknown default: return
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let action = object["action"] as? String else { return }
        if action == "close" {
            close(sessionId: sessionId, sendCloseFrame: false)
            return
        }
        guard action == "input", let input = RemoteBrowserProtocol.input(fromRelayFrame: object) else { return }
        armIdleTimeout(sessionId: sessionId)
        session.inputCounts[Self.inputTypeName(input), default: 0] += 1
        // "Choose displays": consumed here, never reaches CGEvent playback — the same
        // shape as BrowserRelayClient's selectTab.
        if case .selectDisplay(let id) = input {
            session.targetDisplayID = CGDirectDisplayID(id)
            return
        }
        play(input, session: session, sessionId: sessionId)
    }

    private func armIdleTimeout(sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        session.idleTask?.cancel()
        session.idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleTimeout))
            guard !Task.isCancelled else { return }
            self?.audit("[desktop] \(sessionId): idle \(Int(Self.idleTimeout))s — closing")
            self?.close(sessionId: sessionId, sendCloseFrame: true)
        }
    }

    private func send(sessionId: String, frame: [String: Any]) {
        guard let session = sessions[sessionId], let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
        session.socket.send(.data(data)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.audit("[desktop] \(sessionId): send failed — \(error.localizedDescription.prefix(160))")
            }
        }
    }

    private func close(sessionId: String, sendCloseFrame: Bool) {
        guard let session = sessions.removeValue(forKey: sessionId) else { return }
        session.idleTask?.cancel()
        session.captureTask?.cancel()
        if sendCloseFrame, let data = try? JSONSerialization.data(withJSONObject: ["action": "close", "sessionId": sessionId]) {
            session.socket.send(.data(data)) { _ in }
        }
        session.socket.cancel(with: .normalClosure, reason: nil)
        let duration = Int(Date().timeIntervalSince(session.openedAt))
        audit("[desktop] \(sessionId): closed — \(duration)s, \(session.framesSent) frames"
            + (session.droppedFrames > 0 ? " (\(session.droppedFrames) dropped)" : "")
            + ", input=\(session.inputCounts)")
    }
}
#endif
