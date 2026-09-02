// Bluetooth-keyboard capture for the tvOS terminal. GameController's GCKeyboard
// is the raw text+modifier API on tvOS (14+): UIKit's hardware-keyboard pipeline
// is documented for iOS/iPadOS/Catalyst only, and tvOS text entry otherwise means
// the full-screen system keyboard. Keycodes arrive as HID usages, so the US-layout
// character mapping (plus shift/ctrl/alt handling and key repeat) lives here.
import Foundation
import GameController

@MainActor
final class TVKeyboardMonitor: ObservableObject {
    /// True while at least one hardware keyboard is attached (drives the UI hint).
    @Published private(set) var keyboardAttached = false

    /// Byte-sequence sink — wired to the active session's `send(bytes:)`.
    var sendBytes: ([UInt8]) -> Void = { _ in }
    /// Arrows honor DECCKM (application cursor keys) via this probe.
    var applicationCursorKeys: () -> Bool = { false }
    /// When false (terminal screen not showing), events are ignored entirely.
    var isCaptureActive: () -> Bool = { false }

    private var observers: [NSObjectProtocol] = []
    private var capsLockOn = false
    private var repeatTask: Task<Void, Never>?
    private var repeatKeyCode: GCKeyCode?

    func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.attach() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.keyboardAttached = GCKeyboard.coalesced != nil
                self?.cancelRepeat()
            }
        })
        attach()
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        cancelRepeat()
    }

    private func attach() {
        guard let keyboardInput = GCKeyboard.coalesced?.keyboardInput else {
            keyboardAttached = false
            return
        }
        keyboardAttached = true
        keyboardInput.keyChangedHandler = { [weak self] input, _, keyCode, pressed in
            // GameController delivers on its handler queue; hop to the main actor
            // where the session (and all of this monitor's state) lives.
            let modifiers = TVKeyModifiers(
                shift: input.button(forKeyCode: .leftShift)?.isPressed == true
                    || input.button(forKeyCode: .rightShift)?.isPressed == true,
                control: input.button(forKeyCode: .leftControl)?.isPressed == true
                    || input.button(forKeyCode: .rightControl)?.isPressed == true,
                alt: input.button(forKeyCode: .leftAlt)?.isPressed == true
                    || input.button(forKeyCode: .rightAlt)?.isPressed == true
            )
            Task { @MainActor [weak self] in
                self?.handle(keyCode: keyCode, pressed: pressed, modifiers: modifiers)
            }
        }
    }

    private func handle(keyCode: GCKeyCode, pressed: Bool, modifiers: TVKeyModifiers) {
        guard isCaptureActive() else { cancelRepeat(); return }

        if !pressed {
            if keyCode == repeatKeyCode { cancelRepeat() }
            return
        }

        if keyCode == .capsLock {
            capsLockOn.toggle()
            return
        }
        if Self.modifierKeyCodes.contains(keyCode) {
            // Modifier state is polled per event; a modifier change also ends any repeat.
            cancelRepeat()
            return
        }

        guard let bytes = bytes(for: keyCode, modifiers: modifiers) else { return }
        sendBytes(bytes)
        startRepeat(keyCode: keyCode, modifiers: modifiers)
    }

    // MARK: Key repeat (GameController does not auto-repeat)

    private func startRepeat(keyCode: GCKeyCode, modifiers: TVKeyModifiers) {
        cancelRepeat()
        guard Self.repeatableKeyCodes.contains(keyCode) || Self.printableMap[keyCode] != nil else { return }
        repeatKeyCode = keyCode
        repeatTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled {
                guard let self, self.repeatKeyCode == keyCode, self.isCaptureActive(),
                      let bytes = self.bytes(for: keyCode, modifiers: modifiers) else { return }
                self.sendBytes(bytes)
                try? await Task.sleep(for: .milliseconds(55))
            }
        }
    }

    private func cancelRepeat() {
        repeatTask?.cancel()
        repeatTask = nil
        repeatKeyCode = nil
    }

    // MARK: Mapping

    private func bytes(for keyCode: GCKeyCode, modifiers: TVKeyModifiers) -> [UInt8]? {
        // Special keys first.
        switch keyCode {
        case .returnOrEnter, .keypadEnter: return [0x0D]
        case .escape: return [0x1B]
        case .deleteOrBackspace: return [0x7F]
        case .tab: return modifiers.shift ? Array("\u{1B}[Z".utf8) : [0x09]
        case .spacebar: return modifiers.control ? [0x00] : [0x20]
        case .upArrow: return cursorSequence("A")
        case .downArrow: return cursorSequence("B")
        case .rightArrow: return cursorSequence("C")
        case .leftArrow: return cursorSequence("D")
        case .home: return Array("\u{1B}[H".utf8)
        case .end: return Array("\u{1B}[F".utf8)
        case .pageUp: return Array("\u{1B}[5~".utf8)
        case .pageDown: return Array("\u{1B}[6~".utf8)
        case .deleteForward: return Array("\u{1B}[3~".utf8)
        case .F1: return Array("\u{1B}OP".utf8)
        case .F2: return Array("\u{1B}OQ".utf8)
        case .F3: return Array("\u{1B}OR".utf8)
        case .F4: return Array("\u{1B}OS".utf8)
        case .F5: return Array("\u{1B}[15~".utf8)
        case .F6: return Array("\u{1B}[17~".utf8)
        case .F7: return Array("\u{1B}[18~".utf8)
        case .F8: return Array("\u{1B}[19~".utf8)
        case .F9: return Array("\u{1B}[20~".utf8)
        case .F10: return Array("\u{1B}[21~".utf8)
        case .F11: return Array("\u{1B}[23~".utf8)
        case .F12: return Array("\u{1B}[24~".utf8)
        default: break
        }

        guard let pair = Self.printableMap[keyCode] else { return nil }
        var character = modifiers.shift ? pair.shifted : pair.base
        if capsLockOn, !modifiers.shift, pair.base.isLetter {
            character = Character(pair.base.uppercased())
        }

        if modifiers.control, let controlByte = Self.controlCode(for: character) {
            return modifiers.alt ? [0x1B, controlByte] : [controlByte]
        }
        let utf8 = Array(String(character).utf8)
        return modifiers.alt ? [0x1B] + utf8 : utf8
    }

    private func cursorSequence(_ letter: String) -> [UInt8] {
        let prefix = applicationCursorKeys() ? "\u{1B}O" : "\u{1B}["
        return Array((prefix + letter).utf8)
    }

    /// Same rule the iOS on-screen Ctrl key uses (FinTerminalView.controlCode).
    private static func controlCode(for character: Character) -> UInt8? {
        guard let ascii = Character(character.uppercased()).asciiValue, (64...95).contains(ascii) else {
            return nil
        }
        return ascii - 64
    }

    private static let modifierKeyCodes: Set<GCKeyCode> = [
        .leftShift, .rightShift, .leftControl, .rightControl,
        .leftAlt, .rightAlt, .leftGUI, .rightGUI,
    ]

    private static let repeatableKeyCodes: Set<GCKeyCode> = [
        .deleteOrBackspace, .deleteForward, .spacebar, .returnOrEnter,
        .upArrow, .downArrow, .leftArrow, .rightArrow, .pageUp, .pageDown,
    ]

    /// US layout, base + shifted.
    private static let printableMap: [GCKeyCode: (base: Character, shifted: Character)] = [
        .keyA: ("a", "A"), .keyB: ("b", "B"), .keyC: ("c", "C"), .keyD: ("d", "D"),
        .keyE: ("e", "E"), .keyF: ("f", "F"), .keyG: ("g", "G"), .keyH: ("h", "H"),
        .keyI: ("i", "I"), .keyJ: ("j", "J"), .keyK: ("k", "K"), .keyL: ("l", "L"),
        .keyM: ("m", "M"), .keyN: ("n", "N"), .keyO: ("o", "O"), .keyP: ("p", "P"),
        .keyQ: ("q", "Q"), .keyR: ("r", "R"), .keyS: ("s", "S"), .keyT: ("t", "T"),
        .keyU: ("u", "U"), .keyV: ("v", "V"), .keyW: ("w", "W"), .keyX: ("x", "X"),
        .keyY: ("y", "Y"), .keyZ: ("z", "Z"),
        .one: ("1", "!"), .two: ("2", "@"), .three: ("3", "#"), .four: ("4", "$"),
        .five: ("5", "%"), .six: ("6", "^"), .seven: ("7", "&"), .eight: ("8", "*"),
        .nine: ("9", "("), .zero: ("0", ")"),
        .hyphen: ("-", "_"), .equalSign: ("=", "+"),
        .openBracket: ("[", "{"), .closeBracket: ("]", "}"),
        .backslash: ("\\", "|"), .semicolon: (";", ":"), .quote: ("'", "\""),
        .graveAccentAndTilde: ("`", "~"), .comma: (",", "<"),
        .period: (".", ">"), .slash: ("/", "?"),
        .keypadSlash: ("/", "/"), .keypadAsterisk: ("*", "*"),
        .keypadHyphen: ("-", "-"), .keypadPlus: ("+", "+"),
        .keypad0: ("0", "0"), .keypad1: ("1", "1"), .keypad2: ("2", "2"),
        .keypad3: ("3", "3"), .keypad4: ("4", "4"), .keypad5: ("5", "5"),
        .keypad6: ("6", "6"), .keypad7: ("7", "7"), .keypad8: ("8", "8"),
        .keypad9: ("9", "9"), .keypadPeriod: (".", "."),
    ]
}

struct TVKeyModifiers {
    let shift: Bool
    let control: Bool
    let alt: Bool
}
