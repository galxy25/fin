import SwiftUI

struct HomeView: View {
    private enum Mode: String, CaseIterable {
        case terminal = "Terminal"
        case markdown = "Files"
        case agents = "Agents"

        var title: String {
            switch self {
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

    @EnvironmentObject private var entitlementStore: EntitlementStore
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .terminal
    @State private var showsPaywall = false
    #if os(iOS)
    @State private var showsVoiceSetup = false
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { mode in
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
            // Always-available way to reach the Fin Pro subscription — the paywall
            // otherwise only appears once the 14-day trial lapses, so during the
            // trial (or for a reviewer on a fresh install) there was no way to see
            // or buy the subscription. Hidden once the user already has Pro.
            .toolbar {
                if !entitlementStore.isSubscribed && !entitlementStore.ownsLifetime {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showsPaywall = true
                        } label: {
                            Label("Fin Pro", systemImage: "crown")
                        }
                        .labelStyle(.titleAndIcon)
                        .accessibilityLabel("Fin Pro subscription")
                    }
                }
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
            .sheet(isPresented: $showsPaywall) {
                PaywallView()
                    .environmentObject(entitlementStore)
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
