import SwiftTerm

#if os(macOS)
import AppKit

final class FinTerminalView: TerminalView {
    var onCopy: ((String) -> Void)?

    override func copy(_ sender: Any) {
        let text = getSelection()
        super.copy(sender)
        if let text, !text.isEmpty {
            onCopy?(text)
        }
    }
}

#else
import UIKit

final class FinTerminalView: TerminalView {
    var onCopy: ((String) -> Void)?
    /// Fires whenever this view becomes or resigns first responder, i.e. whenever
    /// the on-screen keyboard (and its accessory row) shows or hides.
    var onFirstResponderChange: ((Bool) -> Void)?

    /// When true, the next inserted character is interpreted as a Ctrl-combo
    /// (e.g. armed + "c" sends 0x03) instead of being typed normally. iOS/
    /// visionOS only — a real Mac keyboard's physical Ctrl key already works
    /// via SwiftTerm's own NSEvent handling, no on-screen-keyboard workaround needed.
    var ctrlArmed = false

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFirstResponderChange?(true) }
        return became
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFirstResponderChange?(false) }
        return resigned
    }

    override func copy(_ sender: Any?) {
        let text = getSelection()
        super.copy(sender)
        if let text, !text.isEmpty {
            onCopy?(text)
        }
    }

    override func insertText(_ text: String) {
        guard ctrlArmed else {
            super.insertText(text)
            return
        }
        ctrlArmed = false

        guard text.count == 1, let scalar = text.unicodeScalars.first,
              let controlByte = Self.controlCode(for: scalar) else {
            super.insertText(text)
            return
        }
        terminalDelegate?.send(source: self, data: [controlByte][...])
    }

    private static func controlCode(for scalar: Unicode.Scalar) -> UInt8? {
        guard let asciiValue = Character(scalar).uppercased().unicodeScalars.first?.value,
              (64...95).contains(asciiValue) else { return nil }
        return UInt8(asciiValue - 64)
    }
}
#endif
