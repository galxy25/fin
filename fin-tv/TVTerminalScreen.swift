// The tvOS terminal screen: a top strip (thread selector in agent mode, page
// up/down, the keyboard↔agent mode toggle, the command field, close), the
// content (terminal canvas or the agent conversation), and the bottom strip
// (status plus the same control keys the iPhone accessory row has: Ctrl, Esc,
// Tab, arrows, Enter). Levi's spec, 2026-09-12.
import SwiftUI
import SwiftData

enum TVScreenMode: String, CaseIterable {
    /// The SSH session is on screen; typed commands and keys go to it.
    case keyboard
    /// The agent's conversation is on screen; typed commands go to the agent.
    case agent

    var systemImage: String { self == .keyboard ? "keyboard" : "sparkles" }
    var title: String { self == .keyboard ? "Keyboard" : "Agent" }
    var prompt: String { self == .keyboard ? "Type a command…" : "Message Fin…" }
}

struct TVTerminalScreen: View {
    let server: Server
    @EnvironmentObject private var sessionManager: TVSessionManager
    @EnvironmentObject private var keyboardMonitor: TVKeyboardMonitor
    @EnvironmentObject private var account: TVCloudAccount
    @Query(sort: \Agent.createdAt) private var agents: [Agent]
    @AppStorage("themeBackgroundHex") private var themeBackgroundHex: String = "#000000"
    @AppStorage("themeForegroundHex") private var themeForegroundHex: String = "#00FF00"
    @AppStorage("tv.screenMode") private var modeRaw: String = TVScreenMode.keyboard.rawValue

    @State private var command = ""
    @State private var ctrlLatched = false
    @State private var scrollTarget = 0
    @State private var showsThreadsNote = false
    @State private var agentClient: TVAgentClient?

    private var mode: TVScreenMode { TVScreenMode(rawValue: modeRaw) ?? .keyboard }

    var body: some View {
        Group {
            if let session = sessionManager.sessions[server.id] {
                VStack(spacing: 0) {
                    topStrip(session: session)
                    content(session: session)
                    bottomStrip(session: session)
                }
                .background(Color(uiColor: UIColor(hexString: themeBackgroundHex) ?? .black))
            } else {
                ProgressView()
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .navigationBarBackButtonHidden(false)
        .task { sessionManager.open(server) }
        .onAppear {
            sessionManager.activeServerID = server.id
            keyboardMonitor.isCaptureActive = { [modeRaw] in modeRaw == TVScreenMode.keyboard.rawValue }
            ensureAgentClient()
            if mode == .agent { agentClient?.startPolling() }
        }
        .onDisappear {
            keyboardMonitor.isCaptureActive = { false }
            agentClient?.stopPolling()
        }
        .onChange(of: modeRaw) { _, raw in
            keyboardMonitor.isCaptureActive = { raw == TVScreenMode.keyboard.rawValue }
            if raw == TVScreenMode.agent.rawValue { ensureAgentClient(); agentClient?.startPolling() } else { agentClient?.stopPolling() }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(session: TVTerminalSession) -> some View {
        switch mode {
        case .keyboard:
            TerminalCanvas(session: session, backgroundHex: themeBackgroundHex, foregroundHex: themeForegroundHex)
        case .agent:
            if let agentClient {
                TVTranscriptView(client: agentClient, scrollTarget: $scrollTarget)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.secondary)
                    Text(agents.isEmpty
                         ? "No agent has synced to this Apple TV yet."
                         : "Sign in with Apple on the server list to talk to Fin from here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Top strip

    @ViewBuilder
    private func topStrip(session: TVTerminalSession) -> some View {
        HStack(spacing: 18) {
            if mode == .agent {
                // Thread selector — a placeholder until threads land (docs/THREADS.md).
                Button {
                    showsThreadsNote.toggle()
                } label: {
                    Label("Threads", systemImage: "list.bullet.rectangle")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Threads")
            }
            Button { pageUp() } label: { Image(systemName: "chevron.up.2") }
                .accessibilityLabel(mode == .keyboard ? "Page up" : "Earlier in the conversation")
            Button { pageDown() } label: { Image(systemName: "chevron.down.2") }
                .accessibilityLabel(mode == .keyboard ? "Page down" : "Later in the conversation")
            Button {
                modeRaw = (mode == .keyboard ? TVScreenMode.agent : .keyboard).rawValue
            } label: {
                Label(mode.title, systemImage: mode.systemImage)
            }
            .accessibilityLabel(mode == .keyboard ? "Switch to agent mode" : "Switch to keyboard mode")
            TextField(mode.prompt, text: $command)
                .font(.footnote)
                .frame(maxWidth: 520)
                .onSubmit(submitCommand)
            if showsThreadsNote, mode == .agent {
                Text("Threads are coming: one place per request.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                sessionManager.close(server.id)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.red)
            }
            .accessibilityLabel("Close session")
        }
        .font(.footnote)
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
    }

    // MARK: - Bottom strip

    @ViewBuilder
    private func bottomStrip(session: TVTerminalSession) -> some View {
        HStack(spacing: 14) {
            Circle()
                .fill(stateColor(session.state))
                .frame(width: 12, height: 12)
            Text(session.remoteTitle.isEmpty ? server.name : session.remoteTitle)
                .font(.footnote)
                .monospaced()
                .lineLimit(1)
            if let error = session.lastError {
                Text(error).font(.footnote).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
            switch mode {
            case .keyboard:
                keyButton("Ctrl", highlighted: ctrlLatched) { ctrlLatched.toggle() }
                keyButton("Esc") { sendKey(TerminalControlKeys.escape, session: session) }
                keyButton("Tab") { sendKey(TerminalControlKeys.tab, session: session) }
                ForEach([TerminalControlKeys.Arrow.left, .down, .up, .right], id: \.self) { arrow in
                    keyButton(arrow.glyph) {
                        sendKey(TerminalControlKeys.arrow(arrow, applicationCursor: session.applicationCursorKeys), session: session)
                    }
                }
                keyButton("Enter") { sendKey(TerminalControlKeys.enter, session: session) }
                if keyboardMonitor.keyboardAttached {
                    Image(systemName: "keyboard.fill").foregroundStyle(.secondary)
                }
            case .agent:
                if let agentClient {
                    Text(agentStatus(agentClient))
                        .font(.footnote)
                        .foregroundStyle(agentClient.lastError == nil ? Color.secondary : Color.orange)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
    }

    private func keyButton(_ title: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 20, weight: .medium, design: .monospaced))
                .padding(.horizontal, 6)
        }
        .tint(highlighted ? .accentColor : nil)
        .accessibilityLabel(title == "Ctrl" ? (highlighted ? "Ctrl, latched" : "Ctrl") : title)
    }

    // MARK: - Actions

    private func ensureAgentClient() {
        guard agentClient == nil, account.isSignedIn, let agent = agents.first else { return }
        agentClient = TVAgentClient(
            agentName: agent.name,
            endpoint: { [account] in account.endpoint },
            token: { [account] in account.sessionToken }
        )
    }

    private func pageUp() {
        switch mode {
        case .keyboard: sessionManager.activeSession?.send(bytes: TerminalControlKeys.pageUp)
        case .agent: scrollTarget = max(0, scrollTarget - 1)
        }
    }

    private func pageDown() {
        switch mode {
        case .keyboard: sessionManager.activeSession?.send(bytes: TerminalControlKeys.pageDown)
        case .agent: scrollTarget = min(max(0, (agentClient?.turns.count ?? 1) - 1), scrollTarget + 1)
        }
    }

    private func sendKey(_ bytes: [UInt8], session: TVTerminalSession) {
        if ctrlLatched, bytes.count == 1, let code = TerminalControlKeys.controlCode(for: Character(UnicodeScalar(bytes[0]))) {
            session.send(bytes: [code])
        } else {
            session.send(bytes: bytes)
        }
        ctrlLatched = false
    }

    private func submitCommand() {
        let text = command
        command = ""
        switch mode {
        case .keyboard:
            let bytes = TerminalControlKeys.bytes(forSubmittedCommand: text, ctrlLatched: ctrlLatched)
            ctrlLatched = false
            guard !bytes.isEmpty else { return }
            sessionManager.activeSession?.send(bytes: bytes)
        case .agent:
            guard let agentClient else { return }
            Task {
                await agentClient.send(text)
                scrollTarget = max(0, agentClient.turns.count - 1)
            }
        }
    }

    private func agentStatus(_ client: TVAgentClient) -> String {
        if let error = client.lastError { return error }
        var parts = ["Talking to \(client.agentName)"]
        if let at = client.lastRefreshAt { parts.append("updated \(at.formatted(.relative(presentation: .named)))") }
        let open = client.pending.filter { $0.state != "answered" && $0.state != "failed" }.count
        if open > 0 { parts.append(open == 1 ? "1 message in flight" : "\(open) messages in flight") }
        return parts.joined(separator: " · ")
    }

    private func stateColor(_ state: TVSessionState) -> Color {
        switch state {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .disconnected: return .red
        }
    }
}

/// The conversation, as turns: your line, Fin's reply, heartbeats collapsed to
/// one quiet row, pending sends at the bottom. `scrollTarget` is the turn index
/// the top strip's page buttons move through.
struct TVTranscriptView: View {
    @ObservedObject var client: TVAgentClient
    @Binding var scrollTarget: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if client.turns.isEmpty && client.pending.isEmpty {
                        Text(client.lastRefreshAt == nil ? "Loading the conversation…" : "No conversation yet. Type below to start one.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    }
                    ForEach(Array(client.turns.enumerated()), id: \.element.id) { index, turn in
                        turnRow(turn)
                            .id(index)
                            .focusable()
                    }
                    ForEach(client.pending) { row in
                        pendingRow(row)
                            .id("pending-\(row.id)")
                            .focusable()
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: scrollTarget) { _, target in
                withAnimation { proxy.scrollTo(target, anchor: .top) }
            }
            .onChange(of: client.turns.count) { old, new in
                // Follow the tail when new turns arrive and the reader was at the end.
                if scrollTarget >= old - 1 {
                    scrollTarget = max(0, new - 1)
                    withAnimation { proxy.scrollTo(max(0, new - 1), anchor: .top) }
                }
            }
        }
    }

    @ViewBuilder
    private func turnRow(_ turn: TranscriptTurns.Turn) -> some View {
        if turn.isHeartbeat {
            Label("heartbeat", systemImage: "waveform.path.ecg")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let prompt = turn.prompt {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("You · \(prompt.timestamp.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(prompt.text).font(.callout)
                    }
                }
                if let reply = turn.reply {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fin · \(reply.timestamp.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(reply.text).font(.callout)
                    }
                } else if !turn.steps.isEmpty {
                    Text(turn.steps.count == 1 ? "1 step, no reply yet" : "\(turn.steps.count) steps, no reply yet")
                        .font(.footnote).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func pendingRow(_ row: TVAgentClient.Pending) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("You · \(row.state)")
                .font(.caption)
                .foregroundStyle(row.state == "failed" ? .orange : .secondary)
            Text(row.text).font(.callout)
        }
    }
}
