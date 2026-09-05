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

    @EnvironmentObject private var entitlementStore: EntitlementStore
    @State private var mode: Mode = .terminal
    @State private var showsPaywall = false
    #if os(iOS)
    @State private var showsRemoteKeyboard = false
    @State private var showsVoiceSetup = false
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                switch mode {
                case .terminal:
                    ServerListView()
                case .markdown:
                    MarkdownListView()
                case .agents:
                    AgentListView()
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
            }
            .sheet(isPresented: $showsPaywall) {
                PaywallView()
                    .environmentObject(entitlementStore)
            }
            #if os(iOS)
            // The voice-first pillar's discovery point: how to make "press the
            // Action Button → talk → Fin receives it" real. Sits with the other
            // iOS-only device affordance (the TV remote keyboard).
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
            // Apple TV remote keyboard: the phone as input for Fin on tvOS.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsRemoteKeyboard = true
                    } label: {
                        Image(systemName: "appletv")
                    }
                    .accessibilityLabel("TV Remote Keyboard")
                }
            }
            .sheet(isPresented: $showsRemoteKeyboard) {
                RemoteKeyboardView()
            }
            #endif
        }
    }
}
