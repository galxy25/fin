import Foundation

/// The byte sequences behind Fin's on-screen control keys — one table for the
/// iOS keyboard accessory row, the tvOS control strip, and tests. Pure.
enum TerminalControlKeys {
    enum Arrow: CaseIterable {
        case up, down, left, right

        /// The final letter of the CSI/SS3 cursor sequence.
        var letter: String {
            switch self {
            case .up: return "A"
            case .down: return "B"
            case .right: return "C"
            case .left: return "D"
            }
        }

        var glyph: String {
            switch self {
            case .up: return "\u{2191}"
            case .down: return "\u{2193}"
            case .left: return "\u{2190}"
            case .right: return "\u{2192}"
            }
        }
    }

    static let escape: [UInt8] = [0x1B]
    static let tab: [UInt8] = [0x09]
    static let enter: [UInt8] = [0x0D]
    static let backspace: [UInt8] = [0x7F]
    static let pageUp: [UInt8] = Array("\u{1B}[5~".utf8)
    static let pageDown: [UInt8] = Array("\u{1B}[6~".utf8)

    /// `ESC [ A` normally, `ESC O A` when the application has switched the
    /// terminal into application-cursor mode (vim, less, tmux copy mode).
    static func arrow(_ arrow: Arrow, applicationCursor: Bool) -> [UInt8] {
        Array(((applicationCursor ? "\u{1B}O" : "\u{1B}[") + arrow.letter).utf8)
    }

    /// Same rule the iOS on-screen Ctrl key uses: `@`…`_` map to 0…31, so
    /// Ctrl-C is 0x03 and Ctrl-[ is ESC. Anything else has no control code.
    static func controlCode(for character: Character) -> UInt8? {
        guard let ascii = Character(character.uppercased()).asciiValue, (64...95).contains(ascii) else {
            return nil
        }
        return ascii - 64
    }

    /// What a typed command becomes on the wire. With the Ctrl latch set and a
    /// single character typed, it is that character's control code (so typing
    /// "c" then Enter with Ctrl lit sends Ctrl-C); otherwise the text plus a
    /// carriage return. An empty command with the latch set sends nothing.
    static func bytes(forSubmittedCommand text: String, ctrlLatched: Bool) -> [UInt8] {
        if ctrlLatched {
            guard text.count == 1, let character = text.first, let code = controlCode(for: character) else {
                return text.isEmpty ? [] : Array(text.utf8) + enter
            }
            return [code]
        }
        return Array(text.utf8) + enter
    }
}
