import SwiftUI

/// The app's menu bar. Declared once and ungated: macOS and visionOS get real menu
/// items, iPadOS surfaces the same shortcuts as key commands, and iPhone — with no
/// menu bar and no ⌘ key — simply never fires them, which is why every action here
/// also exists as a tap in `TerminalTabBarView`.
///
/// These have to be menu commands rather than `.onKeyPress`: the AppKit terminal view
/// holds first responder whenever a session is visible, so SwiftUI's focus-based key
/// handling never runs. NSMenu key-equivalent dispatch happens *before* `keyDown`
/// reaches it — which is also why the chords below are picked from the ones the TTY
/// does not want. ⌘←/⌘→ in particular are NOT bound: SwiftTerm maps them to
/// `moveToLeftEndOfLine:`/`moveToRightEndOfLine:` and sends ESC b / ESC f, i.e. the
/// shell's back-word / forward-word, and a menu equivalent would silently take that
/// away from every session. ⌘↑/⌘↓ and ⇧⌘arrow fall through SwiftTerm's unhandled
/// selector default and send nothing, so they are free.
struct FinCommands: Commands {
    @ObservedObject var sessionManager: SessionManager

    var body: some Commands {
        CommandGroup(after: .newItem) {
            // The ellipsis is honest: unlike Terminal.app, ⌘T can't open a tab
            // outright — a Fin terminal needs a server, so it asks which one.
            Button("New Terminal…") {
                sessionManager.isServerPickerPresented = true
            }
            .keyboardShortcut("t", modifiers: .command)
        }

        CommandGroup(after: .windowArrangement) {
            Button("Next Tab") { sessionManager.selectTab(offset: 1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!canCycle)
            Button("Previous Tab") { sessionManager.selectTab(offset: -1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!canCycle)
            // The Terminal.app/Safari pairs, as aliases on the same actions —
            // SwiftUI allows one shortcut per item, so muscle memory needs its own.
            Button("Show Next Tab") { sessionManager.selectTab(offset: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                .disabled(!canCycle)
            Button("Show Previous Tab") { sessionManager.selectTab(offset: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                .disabled(!canCycle)
            Button("Select Next Tab") { sessionManager.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(!canCycle)
            Button("Select Previous Tab") { sessionManager.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(!canCycle)

            Divider()

            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? "Last Tab" : "Tab \(number)") {
                    sessionManager.selectTab(at: number - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                .disabled(sessionManager.tabOrder.isEmpty)
            }
        }
    }

    private var canCycle: Bool { sessionManager.tabOrder.count > 1 }
}
