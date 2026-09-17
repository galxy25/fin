import SwiftUI

/// Marks the scene that actually owns terminal tabs.
///
/// Menu commands are app-global, but ⌘W is not: pressed over the Agent Hub or a
/// Markdown window it has to close THAT window, not reach across and kill a
/// terminal the user can't even see. A focused scene value is how a global menu
/// asks "is the window in front the one I act on" — it resolves to nil in every
/// other scene, which disables Close Tab, and a disabled item does not consume its
/// key equivalent, so ⌘W falls through to AppKit's own Close. That fall-through is
/// the whole mechanism; without it this would need window-identifier sniffing.
private struct TerminalTabsSceneKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var hostsTerminalTabs: Bool? {
        get { self[TerminalTabsSceneKey.self] }
        set { self[TerminalTabsSceneKey.self] = newValue }
    }
}

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
/// away from every session. ⇧⌘arrow falls through SwiftTerm's unhandled-selector
/// default and sends nothing, so it is free — which is why tab cycling lives there,
/// matching Terminal.app and Safari rather than inventing a chord.
struct FinCommands: Commands {
    @ObservedObject var sessionManager: SessionManager
    @FocusedValue(\.hostsTerminalTabs) private var hostsTerminalTabs

    var body: some Commands {
        CommandGroup(after: .newItem) {
            // The ellipsis is honest: unlike Terminal.app, ⌘T can't open a tab
            // outright — a Fin terminal needs a server, so it asks which one.
            Button("New Terminal…") {
                sessionManager.isServerPickerPresented = true
            }
            .keyboardShortcut("t", modifiers: .command)

            // ⌘W, the chord every Mac user already has in their fingers, and the one
            // Terminal.app spends on exactly this. It deliberately shadows the
            // standard Close only while a tab is actually open in the front window;
            // with no tabs it stays disabled and ⌘W means Close Window again, so the
            // shortcut is never dead.
            Button("Close Tab") {
                guard let serverID = sessionManager.activeServerID else { return }
                sessionManager.close(serverID)
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(!canCloseTab)
        }

        CommandGroup(after: .windowArrangement) {
            // ONE pair, not three. An earlier version bound ⌘↑/⌘↓ and offered
            // ⇧⌘arrow and ⇧⌘[ ] as aliases, which cost six Window-menu items for
            // two actions — SwiftUI allows one shortcut per item, so every alias is
            // a visible duplicate. ⇧⌘← / ⇧⌘→ is the chord Terminal.app trains, so
            // it is the chord, and the menu reads as two commands again.
            Button("Next Tab") { sessionManager.selectTab(offset: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                .disabled(!canCycle)
            Button("Previous Tab") { sessionManager.selectTab(offset: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
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

    /// Both halves matter: a terminal has to be frontmost (`hostsTerminalTabs`) AND
    /// there has to be a tab to close. Either one false leaves ⌘W to the window.
    private var canCloseTab: Bool {
        hostsTerminalTabs == true && sessionManager.activeServerID != nil
    }
}
