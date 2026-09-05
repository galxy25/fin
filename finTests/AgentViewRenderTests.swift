import XCTest
import SwiftUI
import SwiftData
@testable import fin

/// Forces a real layout pass over the agent screens. SwiftUI crashes of the "tapped a row
/// and the app died" kind happen during body evaluation, which never runs in a plain
/// model-layer test — hosting the views and laying them out is what actually exercises it.
@MainActor
final class AgentViewRenderTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([
                Server.self, KeyMetadata.self, Agent.self,
                AgentSignal.self, AgentRelayMessage.self,
                Clipping.self, MarkdownDocument.self, AgentLogEntry.self,
            ]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
    }

    /// Hosts the view in a real window and forces layout on whichever platform is running.
    private func render(_ view: some View, file: StaticString = #filePath, line: UInt = #line) {
        #if os(macOS)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        // A view demanding unbounded width blows the window up long before AppKit throws;
        // catching it here names the offending screen instead of killing the whole run.
        XCTAssertLessThan(
            window.frame.width, 5_000,
            "window width ran away — a subview is demanding unbounded width",
            file: file, line: line
        )
        window.orderOut(nil)
        #else
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        // A runloop turn lets SwiftUI actually evaluate and commit the body.
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        window.isHidden = true
        #endif
    }

    func testRendersAgentListWithSeededAgent() throws {
        let container = try makeContainer()
        container.mainContext.insert(Agent(name: "Fin", modelIdentifier: "test-model"))
        try container.mainContext.save()

        render(
            NavigationStack { AgentListView() }
                .modelContainer(container)
                .environmentObject(SessionManager())
        )
    }

    /// The armed-monitor row variant, with the binoculars indicator visible.
    func testRendersAgentListWithArmedMonitor() throws {
        let container = try makeContainer()
        let agent = Agent(name: "Fin", modelIdentifier: "test-model", defaultMode: .auto, heartbeatSeconds: 30)
        agent.monitoringArmed = true
        container.mainContext.insert(agent)
        try container.mainContext.save()

        render(
            NavigationStack { AgentListView() }
                .modelContainer(container)
                .environmentObject(SessionManager())
        )
    }

    func testRendersAgentListWhenEmpty() throws {
        let container = try makeContainer()
        render(
            NavigationStack { AgentListView() }
                .modelContainer(container)
                .environmentObject(SessionManager())
        )
    }

    func testRendersAgentEditorForDefaultAgent() throws {
        let container = try makeContainer()
        let agent = Agent(name: "Fin", modelIdentifier: "test-model")
        container.mainContext.insert(agent)
        try container.mainContext.save()

        render(
            NavigationStack { AgentEditView(agent: agent) }
                .modelContainer(container)
        )
    }

    /// The "add a new one" path — a bare agent with every field at its default.
    func testRendersAgentEditorForBrandNewAgent() throws {
        let container = try makeContainer()
        let agent = Agent(name: "New Agent")
        container.mainContext.insert(agent)
        try container.mainContext.save()

        render(
            NavigationStack { AgentEditView(agent: agent) }
                .modelContainer(container)
        )
    }

    func testRendersLogViewWithEntries() throws {
        let container = try makeContainer()
        let agent = Agent(name: "Fin")
        container.mainContext.insert(agent)

        let runID = UUID()
        for (index, kind) in [AgentLogKind.userMessage, .assistantMessage, .toolCall, .toolResult].enumerated() {
            container.mainContext.insert(AgentLogEntry(record: AgentLogRecord(
                agentID: agent.id,
                agentName: agent.name,
                serverName: "box",
                runID: runID,
                sequence: index,
                kind: kind,
                text: "line \(index)\nwith a second line to force the collapsible path",
                toolName: kind == .toolCall ? "send_input" : nil,
                disposition: kind == .toolCall ? .approved : nil,
                promptTokens: 100,
                completionTokens: 20,
                totalTokens: 120,
                latencyMS: 800,
                timeToFirstTokenMS: 200
            )))
        }
        try container.mainContext.save()

        render(
            NavigationStack { AgentLogView(agent: agent) }
                .modelContainer(container)
        )
    }

    func testRendersMemoryViewWithProfileAndEpisodes() throws {
        let container = try makeContainer()
        let agent = Agent(name: "Fin")
        container.mainContext.insert(agent)
        container.mainContext.insert(AgentMemory(
            kind: .cumulative,
            title: "profile",
            content: "Levi is shipping Fin; prefers direct answers and real end-to-end tests."
        ))
        container.mainContext.insert(AgentMemory(
            kind: .episodic,
            agentID: agent.id,
            conversationID: UUID(),
            title: "Verified sync features",
            content: "Q: does sync work / A: yes, after zone rebuild",
            tags: "auto,conversation"
        ))
        // An old episode outside the lookback and another agent's episode must not render.
        container.mainContext.insert(AgentMemory(
            kind: .episodic,
            agentID: UUID(),
            conversationID: UUID(),
            title: "someone else's conversation"
        ))
        try container.mainContext.save()

        render(
            NavigationStack { AgentMemoryView(agent: agent) }
                .modelContainer(container)
        )
    }

    func testRendersMemoryViewWhenEmpty() throws {
        let container = try makeContainer()
        let agent = Agent(name: "Fin")
        container.mainContext.insert(agent)
        try container.mainContext.save()

        render(
            NavigationStack { AgentMemoryView(agent: agent) }
                .modelContainer(container)
        )
    }

    func testRendersLogViewWhenEmpty() throws {
        let container = try makeContainer()
        let agent = Agent(name: "Fin")
        container.mainContext.insert(agent)
        try container.mainContext.save()

        render(
            NavigationStack { AgentLogView(agent: agent) }
                .modelContainer(container)
        )
    }

    /// The provider switch changes which sections the form builds, so both shapes need a
    /// real layout pass — a crash here would only ever show up as "tapped and it died".
    func testRendersEditorForBothProviders() throws {
        let container = try makeContainer()
        for provider in AgentProvider.allCases {
            let agent = Agent(name: "Fin", provider: provider)
            container.mainContext.insert(agent)
            try container.mainContext.save()
            render(
                NavigationStack { AgentEditView(agent: agent) }
                    .modelContainer(container)
            )
        }
    }

    /// Values stored outside a `Stepper`'s range trap at runtime; the editor clamps, and
    /// this is the regression guard for that.
    func testRendersEditorWithOutOfRangeStoredLimits() throws {
        let container = try makeContainer()
        let agent = Agent(name: "Odd")
        agent.contextWindowTokens = 1            // below the stepper's lower bound
        agent.maxOutputTokens = 999_999          // above its upper bound
        agent.terminalContextLines = 0
        agent.temperature = 0.35
        container.mainContext.insert(agent)
        try container.mainContext.save()

        render(
            NavigationStack { AgentEditView(agent: agent) }
                .modelContainer(container)
        )
    }

    /// Reasoning traces and heartbeat rows are bespoke message shapes in the console —
    /// a layout crash there would only surface mid-conversation on a live agent.
    func testRendersConsoleWithTraceAndHeartbeatRows() throws {
        let agent = Agent(name: "Fin", provider: .openAICompatible, modelIdentifier: "m")
        agent.heartbeatSeconds = 60
        let runtime = AgentRuntime(
            agent: agent,
            session: TerminalSession(serverID: UUID()),
            serverName: "box",
            history: [
                AgentMessage(role: .user, text: "watch the build"),
                AgentMessage(role: .system, text: "Thought: the build is still compiling", isLocalOnly: true),
                AgentMessage(role: .user, text: AgentRuntime.heartbeatPrompt, isHeartbeat: true),
                AgentMessage(role: .assistant, text: "Still running; no input needed."),
            ]
        )
        render(AgentConsoleView(runtime: runtime))
    }

    /// Forces the remote-supervision health badge's stored inputs to a known state
    /// and scrubs them afterward so these tests never leak into the channel tests.
    private func forceRemoteSupervisionHealthy(_ healthy: Bool) {
        let defaults = UserDefaults.standard
        addTeardownBlock {
            for key in [RemoteSupervisionConfig.enabledKey,
                        RemoteSupervisionConfig.lastPollAtKey,
                        RemoteSupervisionConfig.lastPollStatusKey] {
                defaults.removeObject(forKey: key)
            }
        }
        if healthy {
            defaults.set(true, forKey: RemoteSupervisionConfig.enabledKey)
            defaults.set(Date(), forKey: RemoteSupervisionConfig.lastPollAtKey)
            defaults.set("ok (1 directive(s))", forKey: RemoteSupervisionConfig.lastPollStatusKey)
        } else {
            defaults.set(false, forKey: RemoteSupervisionConfig.enabledKey)
            defaults.removeObject(forKey: RemoteSupervisionConfig.lastPollAtKey)
            defaults.removeObject(forKey: RemoteSupervisionConfig.lastPollStatusKey)
        }
    }

    /// Both badge hosts with the green supervision indicator forced visible.
    func testRendersListAndConsoleWithSupervisionBadgeOn() throws {
        forceRemoteSupervisionHealthy(true)
        XCTAssertTrue(RemoteSupervisionConfig.isHealthy())

        let container = try makeContainer()
        let agent = Agent(name: "Fin", modelIdentifier: "test-model")
        agent.monitoringArmed = true
        container.mainContext.insert(agent)
        try container.mainContext.save()
        render(
            NavigationStack { AgentListView() }
                .modelContainer(container)
                .environmentObject(SessionManager())
        )

        let runtime = AgentRuntime(
            agent: Agent(name: "Fin", provider: .openAICompatible, modelIdentifier: "m"),
            session: TerminalSession(serverID: UUID()),
            serverName: "box"
        )
        render(AgentConsoleView(runtime: runtime))
    }

    /// Same hosts with the indicator forced off — the hidden branch must lay out too.
    func testRendersListAndConsoleWithSupervisionBadgeOff() throws {
        forceRemoteSupervisionHealthy(false)
        XCTAssertFalse(RemoteSupervisionConfig.isHealthy())

        let container = try makeContainer()
        container.mainContext.insert(Agent(name: "Fin", modelIdentifier: "test-model"))
        try container.mainContext.save()
        render(
            NavigationStack { AgentListView() }
                .modelContainer(container)
                .environmentObject(SessionManager())
        )

        let runtime = AgentRuntime(
            agent: Agent(name: "Fin", provider: .openAICompatible, modelIdentifier: "m"),
            session: TerminalSession(serverID: UUID()),
            serverName: "box"
        )
        render(AgentConsoleView(runtime: runtime))
    }

    /// The remote conversation view, fed from a fake mirror root on disk plus a
    /// pending relay message, so the transcript rows AND the "sending…" row lay out.
    func testRendersRemoteConsoleWithMirrorAndPendingRelay() throws {
        let container = try makeContainer()
        let agent = Agent(name: "Fin", modelIdentifier: "test-model")
        agent.monitoringArmed = true
        agent.monitoringDeviceID = "some-other-device"
        container.mainContext.insert(agent)
        container.mainContext.insert(AgentRelayMessage(
            agentID: agent.id, text: "check the deploy", authorDeviceID8: DeviceIdentity.short
        ))
        try container.mainContext.save()

        // A fake ubiquity root with one mirrored day file for this agent.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-console-render-\(UUID().uuidString)")
        let directory = root
            .appendingPathComponent("Documents/AgentLogs")
            .appendingPathComponent(AgentLogMirror.slug(agentName: agent.name, agentID: agent.id))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let lines = [
            AgentLogMirror.line(for: AgentLogRecord(
                agentID: agent.id, agentName: agent.name, serverName: "box",
                runID: UUID(), sequence: 1, kind: .userMessage, text: "watch the build"
            )),
            AgentLogMirror.line(for: AgentLogRecord(
                agentID: agent.id, agentName: agent.name, serverName: "box",
                runID: UUID(), sequence: 2, kind: .assistantMessage, text: "Build is green."
            )),
        ].compactMap { $0 }
        try (lines.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent("\(day).abcd1234.jsonl"),
            atomically: true, encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: root) }

        render(
            AgentRemoteConsoleView(agent: agent, reader: AgentMirrorReader(containerURL: { root }))
                .modelContainer(container)
        )
    }

    /// The agent list's remotely-hosted row variant, with the Remote swipe affordance path built.
    func testRendersAgentListWithRemotelyHostedAgent() throws {
        let container = try makeContainer()
        let agent = Agent(name: "Fin", modelIdentifier: "test-model")
        agent.monitoringArmed = true
        agent.monitoringDeviceID = "not-\(DeviceIdentity.id)"
        container.mainContext.insert(agent)
        try container.mainContext.save()

        render(
            NavigationStack { AgentListView() }
                .modelContainer(container)
                .environmentObject(SessionManager())
        )
    }

    func testRendersHomeViewAcrossAllTabs() throws {
        let container = try makeContainer()
        container.mainContext.insert(Agent(name: "Fin"))
        try container.mainContext.save()

        render(
            HomeView()
                .modelContainer(container)
                .environmentObject(SessionManager())
                // HomeView's Fin Pro toolbar reads the entitlement store; without
                // one injected, the render traps (field-observed suite crash).
                .environmentObject(EntitlementStore())
        )
    }
}
