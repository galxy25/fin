import SwiftUI

struct ControlStripView: View {
    let server: Server
    @ObservedObject var session: TerminalSession
    @EnvironmentObject private var sessionManager: SessionManager

    @State private var showingServers = false
    @State private var showingClipboard = false
    @State private var showingTheme = false
    @State private var showingPageButtons = false
    #if os(iOS) || os(visionOS)
    @State private var pendingKeyboardHide = false
    #endif

    var body: some View {
        HStack(spacing: 18) {
            statusDot
            Text(server.name)
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(1)
            Spacer()
            // Always tappable — including mid-connect/reconnect — so a hung or
            // wrong connection attempt is never a dead end.
            Button {
                sessionManager.close(server.id)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.red)
            }
            Button {
                showingServers = true
            } label: {
                Image(systemName: "server.rack")
            }
            Button {
                showingClipboard = true
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            Button {
                showingTheme = true
            } label: {
                Image(systemName: "paintpalette")
            }
            // A popover instead of a Menu — Menu items dismiss on every tap, which
            // rules out pressing Page Up/Down repeatedly or holding it down.
            Button {
                showingPageButtons = true
            } label: {
                Image(systemName: "line.3.horizontal")
            }
            .popover(isPresented: $showingPageButtons, arrowEdge: .top) {
                HStack(spacing: 28) {
                    RepeatingButton(systemImage: "chevron.up.2") {
                        session.send(text: "\u{1B}[5~")
                    }
                    RepeatingButton(systemImage: "chevron.down.2") {
                        session.send(text: "\u{1B}[6~")
                    }
                    #if os(iOS) || os(visionOS)
                    Button {
                        if session.isKeyboardVisible {
                            // Deferred to .onDisappear below — calling hideKeyboard()
                            // here, before the popover finishes dismissing, gets silently
                            // undone: popover/sheet dismissal in UIKit restores whatever
                            // was first responder before it was presented as a side
                            // effect, which re-shows the keyboard right after we hide it.
                            pendingKeyboardHide = true
                        } else {
                            session.showKeyboard()
                        }
                        showingPageButtons = false
                    } label: {
                        Image(systemName: session.isKeyboardVisible
                            ? "keyboard.chevron.compact.down"
                            : "chevron.up")
                    }
                    #endif
                }
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .padding(20)
                .background(Color.black)
                .presentationCompactAdaptation(.popover)
                #if os(iOS) || os(visionOS)
                .onDisappear {
                    if pendingKeyboardHide {
                        pendingKeyboardHide = false
                        session.hideKeyboard()
                    }
                }
                #endif
            }
        }
        .font(.system(size: 18))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black)
        .sheet(isPresented: $showingServers) {
            HomeView()
        }
        .sheet(isPresented: $showingClipboard) {
            ClipboardManagerView(session: session)
        }
        .sheet(isPresented: $showingTheme) {
            ThemeSettingsView()
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(color(for: session.state))
            .frame(width: 8, height: 8)
    }

    private func color(for state: SessionState) -> Color {
        switch state {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .disconnected: return .red
        }
    }
}

/// A button that fires once immediately on press, then — if still held past a
/// short delay — keeps firing on a fixed interval until released, matching
/// familiar OS key-repeat behavior (e.g. holding a physical Page Up key).
private struct RepeatingButton: View {
    let systemImage: String
    let action: () -> Void

    @State private var isPressing = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: systemImage)
            .contentShape(Rectangle())
            .padding(12)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressing else { return }
                        isPressing = true
                        action()
                        repeatTask = Task {
                            try? await Task.sleep(for: .milliseconds(400))
                            while !Task.isCancelled {
                                action()
                                try? await Task.sleep(for: .milliseconds(120))
                            }
                        }
                    }
                    .onEnded { _ in
                        isPressing = false
                        repeatTask?.cancel()
                        repeatTask = nil
                    }
            )
    }
}
