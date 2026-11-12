import SwiftUI

struct HomeView: View {
    enum Mode: String, CaseIterable {
        /// docs/XANADU.md: the conversation pane — first, and the landing with no terminal open.
        case xanadu = "Fin"
        case terminal = "Terminal"
        case markdown = "Files"
        case agents = "Agents"

        var title: String {
            switch self {
            case .xanadu: return "Fin"
            case .terminal: return "Servers"
            case .markdown: return "Files"
            case .agents: return "Agents"
            }
        }
    }

    /// True only for ControlStripView's server-rack-button sheet (a terminal
    /// session still live underneath) — the root `.home` route is a real window,
    /// not a sheet, and has nothing to close. A sheet's Esc-to-dismiss is a
    /// keyboard-only affordance (native on macOS, easy to miss on iOS too); this
    /// adds a visible close button for anyone who doesn't reach for it.
    var isSheet: Bool = false

    @EnvironmentObject private var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode
    #if os(iOS)
    @State private var showsVoiceSetup = false
    #endif

    /// The root route opens on Xanadu (no tab open, or a tap / Siri asked for
    /// it — docs/XANADU.md decision 1); the server-picker sheet (⌘T, the
    /// control strip) is about terminals and has no conversation segment —
    /// Xanadu is a pane, not something to open over a live terminal.
    init(isSheet: Bool = false) {
        self.isSheet = isSheet
        _mode = State(initialValue: isSheet ? .terminal : .xanadu)
    }

    private var modes: [Mode] { isSheet ? Mode.allCases.filter { $0 != .xanadu } : Mode.allCases }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mode", selection: $mode) {
                    ForEach(modes, id: \.self) { mode in
                        Text(mode.rawValue)
                            .tag(mode)
                            .accessibilityIdentifier("homeMode_\(mode.rawValue)")
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .accessibilityIdentifier("homeModePicker")

                switch mode {
                case .xanadu:
                    XanaduView()
                        .accessibilityIdentifier("xanaduView")
                case .terminal:
                    ServerListView()
                case .markdown:
                    MarkdownListView()
                case .agents:
                    AgentListView()
                        .accessibilityIdentifier("agentListView")
                }
            }
            .navigationTitle(mode.title)
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            // Siri / an intent asked for the conversation: show it.
            .onChange(of: sessionManager.showsXanadu) { _, shows in
                if shows && !isSheet { mode = .xanadu }
            }
            .onReceive(XanaduNavigator.shared.$request) { request in
                if request != nil && !isSheet { mode = .xanadu }
            }
            .toolbar {
                // From Xanadu back to the terminal that was open underneath.
                if mode == .xanadu, !isSheet, sessionManager.activeServerID != nil {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            sessionManager.showsXanadu = false
                        } label: {
                            Label("Terminal", systemImage: "terminal")
                        }
                        .accessibilityIdentifier("xanaduBackToTerminal")
                    }
                }
            }
            .toolbar {
                if isSheet {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .accessibilityLabel("Close")
                        .accessibilityIdentifier("homeSheetCloseButton")
                    }
                }
            }
            #if os(iOS)
            // The voice-first pillar's discovery point: how to make "press the
            // Action Button → talk → Fin receives it" real.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsVoiceSetup = true
                    } label: {
                        Image(systemName: "waveform.badge.mic")
                    }
                    .accessibilityLabel("Set up voice button")
                }
            }
            .sheet(isPresented: $showsVoiceSetup) {
                VoiceSetupView()
            }
            #endif
            #if os(macOS)
            // Unlike iOS, a macOS `.sheet` sizes itself to its content's IDEAL size
            // rather than filling the screen — and a bare `List` with no frame
            // constraint reports a near-zero ideal height. Without this, presenting
            // HomeView as a sheet (ControlStripView's server-rack button, mid-session)
            // collapsed to just tall enough for the segmented Picker, leaving the
            // server/agent list rendered outside the visible window: nothing under
            // the tab bar looked clickable, though the rows were really just
            // off-frame. The root `.home` route (a real window, not a sheet) mostly
            // dodged this because a resized window persists — but a fresh window
            // starts from the same undersized ideal layout, so this also gives that
            // route a sane starting size.
            .frame(minWidth: 480, minHeight: 560)
            #endif
        }
    }
}
