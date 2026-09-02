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

    @State private var mode: Mode = .terminal
    #if os(iOS)
    @State private var showsRemoteKeyboard = false
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
            #if os(iOS)
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
