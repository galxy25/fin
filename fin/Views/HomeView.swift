import SwiftUI

struct HomeView: View {
    private enum Mode: String {
        case terminal = "Terminal"
        case markdown = "Markdown"
    }

    @State private var mode: Mode = .terminal

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mode", selection: $mode) {
                    Text(Mode.terminal.rawValue).tag(Mode.terminal)
                    Text(Mode.markdown.rawValue).tag(Mode.markdown)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                switch mode {
                case .terminal:
                    ServerListView()
                case .markdown:
                    MarkdownListView()
                }
            }
            .navigationTitle(mode == .terminal ? "Servers" : "Markdown")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
}
