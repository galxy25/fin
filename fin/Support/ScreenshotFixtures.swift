import Foundation
import SwiftData
#if os(macOS)
import AppKit
#endif

/// Demo data for App Store screenshot capture, gated on `FIN_SCREENSHOT_MODE=1`
/// in the launch environment — the same shape of env gate `FIN_UI_TESTING` already
/// uses, and never set for a real user.
///
/// Why this exists: the App Store screenshots shipped before this were captured on
/// a fresh install, so every one of them showed an empty state ("No Servers", "No
/// Files") — the least representative possible view of an app whose whole point is
/// an agent driving real sessions. Seeding realistic-looking rows is what lets a
/// capture run produce a product page that shows the app doing its job.
///
/// Everything here is SYNTHETIC on purpose. Hosts are RFC 5737 / example.com
/// addresses, the profile and conversations are invented in the register of
/// `docs/app-review/voice-examples.md`, and the one real element — "This Mac",
/// a loopback SSH session to the capturing machine — carries no name but its own.
/// A screenshot is a public artifact; the owner's machine names, pane titles and
/// memory do not belong in one.
///
/// The store this seeds is a throwaway (`isolatedStoreDirectory`): finApp builds
/// the model container against it, with no CloudKit mirroring, whenever capture
/// mode is on — so on a Mac the fixtures no longer land in the real synced
/// container and propagate to every device on the Apple Account.
enum ScreenshotFixtures {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["FIN_SCREENSHOT_MODE"] == "1"
    }

    /// Kept for the pre-isolated-store era: a capture that once ran against the
    /// real container may have left these named rows behind, and relaunching with
    /// `FIN_SCREENSHOT_CLEANUP=1` still removes exactly them.
    static var isCleanupRequested: Bool {
        ProcessInfo.processInfo.environment["FIN_SCREENSHOT_CLEANUP"] == "1"
    }

    /// The throwaway store for a capture run, wiped on every launch so each
    /// capture starts from the same rows. Nil outside capture mode.
    static func isolatedStoreDirectory() -> URL? {
        guard isEnabled else { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("fin-screenshots/store", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Sizes the window that just appeared to a Mac App Store screenshot size in
    /// points (1440×900 on a 2× display is exactly the 2880×1800 asset), so a
    /// window capture needs no framing. A no-op outside capture mode and off macOS.
    /// Deferred a beat: at `onAppear` the NSWindow behind a SwiftUI scene may not
    /// be the key window yet.
    static func sizeWindowForCapture(width: CGFloat, height: CGFloat) {
        #if os(macOS)
        guard isEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let window = NSApp.keyWindow ?? NSApp.windows.last else { return }
            let screen = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
            let origin = NSPoint(x: screen.midX - width / 2, y: screen.midY - height / 2)
            window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        }
        #endif
    }

    private static let serverNames = ["This Mac", "Studio iMac", "Build Box", "Cloud Worker"]
    private static let agentNames = ["Nimbus", "Relay"]
    private static let documentNames = ["Deploy Runbook.md", "Incident Notes.md", "Scratch.md"]

    /// A fixed id so the loopback key's Keychain item is replaced, never duplicated,
    /// across capture runs.
    static let loopbackKeyID = UUID(uuidString: "5C2EE1A0-0000-4000-8000-F1F1F1F1F1F1")!

    /// Deletes exactly the rows `seedIfNeeded` inserts, matched by their fixture
    /// names. Deliberately does NOT touch "Fin": a real user's own agent is named
    /// that, and deleting it because a capture once seeded one would destroy real
    /// data — the stray duplicate is the lesser harm and is obvious in the UI.
    static func cleanup(_ context: ModelContext) {
        guard isCleanupRequested else { return }
        for server in (try? context.fetch(FetchDescriptor<Server>())) ?? []
        where serverNames.contains(server.name) {
            context.delete(server)
        }
        for agent in (try? context.fetch(FetchDescriptor<Agent>())) ?? []
        where agentNames.contains(agent.name) {
            context.delete(agent)
        }
        #if !os(tvOS)
        for document in (try? context.fetch(FetchDescriptor<MarkdownDocument>())) ?? []
        where documentNames.contains(document.name) || document.name == "ui-test-fixture.md" {
            context.delete(document)
        }
        #endif
        try? context.save()
    }

    static func seedIfNeeded(_ context: ModelContext) {
        guard isEnabled else { return }
        // A fresh trial, so the paywall shot reads as a new install's would
        // (EntitlementStore's @AppStorage("trialStartedAt")).
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "trialStartedAt")
        // The console side panel's toggle persists (TerminalScreen's
        // @AppStorage("agentPanelVisible")); a capture must start with it closed
        // or every other run's "open the console" click closes it instead.
        UserDefaults.standard.set(false, forKey: "agentPanelVisible")
        let agentID = seedAgents(context)
        seedServers(context)
        seedMemory(context, agentID: agentID)
        #if !os(tvOS)
        // AgentLogEntry and MarkdownDocument are local-only models the tvOS target
        // deliberately omits, so they aren't in fin-tv's schema.
        seedTrail(context, agentID: agentID)
        seedDocuments(context)
        #endif
        try? context.save()
    }

    // MARK: - Servers

    private static func seedServers(_ context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<Server>())) ?? []
        guard existing.isEmpty else { return }
        // "This Mac" is the one live row: a loopback SSH session to the machine
        // running the capture, so the terminal screenshot shows a real shell. The
        // key is a throwaway generated for captures (scripts/screenshots/
        // prepare-mac.sh); absent, the row is still seeded and simply won't connect.
        // The tmux session name is deliberately NOT "main": the capturing
        // machine's own `main` is where its owner works.
        if loopbackKeyPEM() != nil {
            // Metadata only: the PEM itself is handed to `resolveCredentials` straight
            // from `loopbackKeyPEM()` (finApp), never through the Keychain.
            if (try? context.fetch(FetchDescriptor<KeyMetadata>()))?.isEmpty ?? true {
                let metadata = KeyMetadata(name: "fin-screenshots", keyType: .ed25519)
                metadata.id = loopbackKeyID
                context.insert(metadata)
            }
            context.insert(
                Server(
                    name: "This Mac",
                    host: "127.0.0.1",
                    username: ProcessInfo.processInfo.environment["FIN_SCREENSHOT_SSH_USER"] ?? NSUserName(),
                    keyID: loopbackKeyID,
                    tmuxSessionName: "demo",
                    // A bare bash with a neutral prompt inside Fin's own tmux session:
                    // the login shell's prompt would print the owner's user@host.
                    connectCommand: "exec tmux new-session -A -s demo \"env PS1='fin % ' bash --norc --noprofile\" \\; set status off"
                )
            )
        }
        let servers = [
            Server(name: "Studio iMac", host: "studio.example.com", username: "levi", tmuxSessionName: "fin"),
            Server(name: "Build Box", host: "build.example.com", username: "ci", tmuxSessionName: "ci"),
            Server(name: "Cloud Worker", host: "worker.example.com", username: "ubuntu", tmuxSessionName: "agent"),
        ]
        for server in servers {
            context.insert(server)
        }
    }

    /// The loopback private key, from `FIN_SCREENSHOT_KEY_PATH` or the capture
    /// directory next to the throwaway store. OpenSSH format, unencrypted.
    static func loopbackKeyPEM() -> String? {
        var candidates: [URL] = []
        if let path = ProcessInfo.processInfo.environment["FIN_SCREENSHOT_KEY_PATH"], !path.isEmpty {
            candidates.append(URL(fileURLWithPath: path))
        }
        for base in FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask) {
            candidates.append(base.appendingPathComponent("fin-screenshots/id_ed25519"))
        }
        candidates.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/fin-screenshots/id_ed25519")
        )
        for url in candidates {
            if let pem = try? String(contentsOf: url, encoding: .utf8), pem.contains("PRIVATE KEY") {
                return pem
            }
        }
        return nil
    }

    // MARK: - Agents

    /// Returns the id of "Fin", the agent every other fixture hangs off.
    @discardableResult
    private static func seedAgents(_ context: ModelContext) -> UUID {
        let existing = (try? context.fetch(FetchDescriptor<Agent>())) ?? []
        if let fin = existing.first(where: { $0.name == "Fin" }) { return fin.id }
        guard existing.isEmpty else { return existing[0].id }
        // "Fin" is seeded here rather than left to
        // `AgentListView.seedDefaultAgentIfNeeded`: that one only fires when the
        // agent list is empty, and inserting any fixture agent first would
        // suppress it — leaving a capture whose Agents tab is missing the very
        // agent the product is named after.
        let fin = Agent(
            name: "Fin",
            provider: .appleOnDevice,
            contextWindowTokens: 8192,
            defaultMode: .manual
        )
        context.insert(fin)
        context.insert(
            Agent(
                name: "Nimbus",
                provider: .openAICompatible,
                endpointURL: "http://studio.example.com:1234/v1",
                modelIdentifier: "qwen3.6-27b",
                contextWindowTokens: 32768,
                defaultMode: .auto
            )
        )
        context.insert(
            Agent(
                name: "Relay",
                provider: .openAICompatible,
                endpointURL: "http://build.example.com:1234/v1",
                modelIdentifier: "gemma-4-12b",
                contextWindowTokens: 16384,
                defaultMode: .manual
            )
        )
        return fin.id
    }

    // MARK: - Memory

    private static func seedMemory(_ context: ModelContext, agentID: UUID) {
        let existing = (try? context.fetch(FetchDescriptor<AgentMemory>())) ?? []
        guard existing.isEmpty else { return }
        let profile = AgentMemory(
            kind: .cumulative,
            agentID: agentID,
            title: "User profile",
            content: """
            Works across three machines: a studio Mac (primary, always on), a build box that \
            runs the nightly test suite and the release archive, and a cloud worker that picks \
            up long jobs when neither is awake. Everything lives in tmux; sessions are named \
            after the project, and the human's own session is never to be typed into.

            Prefers short, direct answers and a number over an adjective. Wants every command \
            explained in a clause before it runs, and expects approval to be asked for anything \
            that deletes, pushes, or restarts a service. Quiet on green: only failures, blockers \
            and finished long jobs deserve a notification.

            Releases go out on Thursdays after the eval run. Build numbers are timestamps. The \
            deploy runbook in Files is the source of truth for release day; follow it step by \
            step and stop before any destructive step.
            """,
            tags: "profile"
        )
        context.insert(profile)
        let now = Date()
        let episodes: [(String, String, TimeInterval)] = [
            ("Overnight build check on the build box",
             "Asked whether the nightly run finished. 412 tests, 1 failure in the paywall disclosure "
             + "test; reran it alone at the user's request and it passed on the second attempt — flaky, "
             + "noted for the eval run.", -3 * 3600),
            ("Deploy log watch",
             "Tailed the staging deploy log through six steps and notified on the final line. Asset "
             + "sync took the longest (4 min). No intervention needed.", -26 * 3600),
            ("Release 1.0.2 archive",
             "Watched the archive and upload on the build box, reported build number when the "
             + "upload succeeded. Reminded that TestFlight goes to all four platforms together.", -2 * 86400),
            ("Dev server restart in the fin session",
             "Restarted the dev server after a config change; confirmed it was listening on 8080 "
             + "before replying.", -3 * 86400),
        ]
        for (title, content, offset) in episodes {
            let memory = AgentMemory(
                kind: .episodic, agentID: agentID, conversationID: UUID(),
                title: title, content: content, tags: "conversation",
                startedAt: now.addingTimeInterval(offset)
            )
            memory.stoppedAt = now.addingTimeInterval(offset + 600)
            memory.updatedAt = now.addingTimeInterval(offset + 600)
            context.insert(memory)
        }
    }

    #if !os(tvOS)

    // MARK: - Logs & traces (and, through `loadAgentHistory`, the console)

    /// Two runs in the register of docs/app-review/voice-examples.md. The user and
    /// assistant lines double as the console's restored conversation, so the
    /// terminal-plus-console screenshot shows a real exchange without a model.
    private static func seedTrail(_ context: ModelContext, agentID: UUID) {
        let existing = (try? context.fetch(FetchDescriptor<AgentLogEntry>())) ?? []
        guard existing.isEmpty else { return }
        let now = Date()
        var clock = now.addingTimeInterval(-40 * 60)
        func stamp(_ seconds: TimeInterval) -> Date {
            clock = clock.addingTimeInterval(seconds)
            return clock
        }
        struct Line {
            var kind: AgentLogKind
            var text: String
            var tool: String? = nil
            var arguments: String? = nil
            var disposition: AgentToolDisposition? = nil
            var promptTokens: Int? = nil
            var completionTokens: Int? = nil
            var latencyMS: Int? = nil
            var ttftMS: Int? = nil
            var toolMS: Int? = nil
            var approvalMS: Int? = nil
            var after: TimeInterval = 4
        }
        let runs: [[Line]] = [
            [
                Line(kind: .userMessage, text: "Have Fin check whether the overnight build on the build box finished, and tell me if anything failed."),
                Line(kind: .reasoning, text: "The ci session is where the nightly runs. Read its terminal first; only type if the summary isn't on screen.",
                     promptTokens: 1_412, completionTokens: 58, latencyMS: 2_140, ttftMS: 610),
                Line(kind: .toolCall, text: "read_session ci", tool: "read_session",
                     arguments: #"{"session":"ci","lines":80}"#, disposition: .unguarded, toolMS: 340),
                Line(kind: .toolResult, text: """
                    Test Suite 'All tests' failed at 03:12:47.
                         Executed 412 tests, with 1 failure (0 unexpected) in 611.208 (612.4) seconds
                    Failing tests:
                         PaywallDisclosureTests.testRenewalTermsVerbatim
                    ** TEST FAILED **
                    """, toolMS: 340),
                Line(kind: .assistantMessage, text: "The overnight run finished at 03:12 — 412 tests, 1 failure: PaywallDisclosureTests.testRenewalTermsVerbatim. Everything else is green. Want me to rerun just that one and paste the diff?",
                     promptTokens: 1_902, completionTokens: 71, latencyMS: 3_380, ttftMS: 720, after: 25),
                Line(kind: .userMessage, text: "Yes, rerun just that test."),
                Line(kind: .toolCall, text: "send_session ci", tool: "send_session",
                     arguments: #"{"session":"ci","text":"xcodebuild test -scheme fin -only-testing:finTests/PaywallDisclosureTests/testRenewalTermsVerbatim\n"}"#,
                     disposition: .approved, promptTokens: 2_044, completionTokens: 63, latencyMS: 2_910, ttftMS: 640, approvalMS: 6_200),
                Line(kind: .approval, text: "Approved: send_session ci", disposition: .approved),
                Line(kind: .toolResult, text: """
                    Test Case '-[finTests.PaywallDisclosureTests testRenewalTermsVerbatim]' passed (0.412 seconds).
                         Executed 1 test, with 0 failures (0 unexpected) in 0.412 (0.418) seconds
                    ** TEST SUCCEEDED **
                    """, toolMS: 48_300, after: 50),
                Line(kind: .assistantMessage, text: "It passed on its own: 1 test, 0 failures, 0.41 s. That makes it flaky rather than broken — I've noted it for Thursday's eval run.",
                     promptTokens: 2_388, completionTokens: 49, latencyMS: 2_460, ttftMS: 580),
            ],
            [
                Line(kind: .userMessage, text: "Get Fin to tail the deploy log and let me know when it's done.", after: 3),
                Line(kind: .toolCall, text: "send_session deploy", tool: "send_session",
                     arguments: #"{"session":"deploy","text":"tail -f /srv/staging/deploy.log\n"}"#,
                     disposition: .approved, promptTokens: 1_530, completionTokens: 44, latencyMS: 1_980, ttftMS: 560, approvalMS: 4_100),
                Line(kind: .approval, text: "Approved: send_session deploy", disposition: .approved),
                Line(kind: .toolCall, text: "monitor deploy", tool: "monitor",
                     arguments: #"{"session":"deploy","until":"deploy complete","intervalSeconds":30}"#, disposition: .unguarded),
                Line(kind: .assistantMessage, text: "Tailing deploy.log on the build box now. I'll notify you the moment it prints the final \"deploy complete\" line — currently at step 4 of 6, syncing assets.",
                     promptTokens: 1_744, completionTokens: 52, latencyMS: 2_210, ttftMS: 600, after: 240),
                Line(kind: .toolResult, text: """
                    [5/6] restarting app servers … ok (2 nodes)
                    [6/6] health check … 200 OK in 0.31s
                    deploy complete — 2026-09-18 10:41:02
                    """, toolMS: 261_000, after: 6),
                Line(kind: .notice, text: "Notified: Staging deploy finished — 6/6 steps, health check 200 in 0.31 s."),
                Line(kind: .assistantMessage, text: "Done: the staging deploy finished at 10:41 — all six steps, health check 200 OK in 0.31 s. Nothing needed a hand.",
                     promptTokens: 2_012, completionTokens: 41, latencyMS: 1_870, ttftMS: 540),
            ],
        ]
        for lines in runs {
            let runID = UUID()
            for (index, line) in lines.enumerated() {
                var record = AgentLogRecord(
                    agentID: agentID, agentName: "Fin", serverName: "Build Box",
                    runID: runID, sequence: index + 1, kind: line.kind, text: line.text
                )
                record.toolName = line.tool
                record.toolArguments = line.arguments
                record.disposition = line.disposition
                record.modelIdentifier = "apple-on-device"
                record.temperature = 0.2
                record.promptTokens = line.promptTokens
                record.completionTokens = line.completionTokens
                record.totalTokens = line.promptTokens.map { $0 + (line.completionTokens ?? 0) }
                record.latencyMS = line.latencyMS
                record.timeToFirstTokenMS = line.ttftMS
                record.toolDurationMS = line.toolMS
                record.approvalWaitMS = line.approvalMS
                let entry = AgentLogEntry(record: record)
                entry.timestamp = stamp(line.after)
                context.insert(entry)
            }
            clock = clock.addingTimeInterval(15 * 60)
        }
    }

    // MARK: - Fin's computers

    /// What the servers pane, the memory view and the console show as Fin's own
    /// bodies during a capture: three sites in the same three roles the servers
    /// list uses, with pane titles in the voice-examples register. Decoded from
    /// JSON because `FinSite` is a plain `Decodable` shape with no memberwise init.
    static func demoSites(now: Date = Date()) -> [FinSite] {
        let iso = ISO8601DateFormatter()
        func at(_ seconds: TimeInterval) -> String { iso.string(from: now.addingTimeInterval(seconds)) }
        let json = """
        [
          {"siteId":"5c2ee1a0-0000-4000-8000-000000000001","siteId8":"5c2ee1a0","agent":"Fin","kind":"resident",
           "displayName":"Studio iMac","priority":100,"state":"working","live":true,
           "enrolledAt":"\(at(-36 * 86400))","lastHeartbeatAt":"\(at(-8))","leaseUntil":"\(at(52))",
           "capabilities":{"daemon_version":"1.10.1","always_on":true,"terminal_relay":true,
             "brain":{"kind":"apple-on-device","model":"Apple on-device"},
             "tmux_sessions":[
               {"session":"fin","registered":true,"tasks":["fin app","release 1.0.2"],
                "panes":[{"target":"fin:0.0","title":"xcodebuild archive — 71%","command":"xcodebuild","cwd":"fin"},
                         {"target":"fin:1.0","title":"tail deploy.log","command":"tail","cwd":"staging"}]},
               {"session":"docs","registered":false,"tasks":[],
                "panes":[{"target":"docs:0.0","title":"vim runbook.md","command":"vim","cwd":"docs"}]}]},
           "runId":null,"workerId":null},
          {"siteId":"5c2ee1a0-0000-4000-8000-000000000002","siteId8":"7d41b2c9","agent":"Fin","kind":"byo",
           "displayName":"Build Box","priority":80,"state":"idle","live":true,
           "enrolledAt":"\(at(-20 * 86400))","lastHeartbeatAt":"\(at(-14))","leaseUntil":"\(at(46))",
           "capabilities":{"daemon_version":"1.10.1","always_on":true,"terminal_relay":true,
             "brain":{"kind":"openai-compatible","model":"qwen3.6-27b"},
             "tmux_sessions":[
               {"session":"ci","registered":true,"tasks":["nightly tests","eval run"],
                "panes":[{"target":"ci:0.0","title":"412 tests, 0 failures","command":"fish","cwd":"fin"}]}]},
           "runId":null,"workerId":null},
          {"siteId":"5c2ee1a0-0000-4000-8000-000000000003","siteId8":"a91c04e7","agent":"Fin","kind":"ec2",
           "displayName":"Cloud Worker","priority":10,"state":"idle","live":false,
           "enrolledAt":"\(at(-12 * 86400))","lastHeartbeatAt":"\(at(-5 * 3600))","leaseUntil":"\(at(-5 * 3600 + 60))",
           "capabilities":{"daemon_version":"1.10.1","always_on":false,"terminal_relay":true,
             "brain":{"kind":"openai-compatible","model":"gemma-4-12b"},"tmux_sessions":[]},
           "runId":null,"workerId":"w-2f0c"}
        ]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([FinSite].self, from: Data(json.utf8))) ?? []
    }

    // MARK: - Files

    private static func seedDocuments(_ context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<MarkdownDocument>())) ?? []
        guard existing.isEmpty else { return }
        let fixtures: [(String, String)] = [
            ("Deploy Runbook.md", """
            # Deploy Runbook

            Steps Fin drives on release day, in order. Each one is a command it
            types into the build session and then watches to completion.

            ## 1. Cut the branch

            Tag `main` and push, then wait for CI to go green before anything
            else starts. Fin reports back if a check goes red.

            ## 2. Archive and upload

            The archive step takes roughly twelve minutes. Fin keeps the session
            alive, watches for the signing prompt, and pings when it needs a
            decision from a human.

            ## 3. Smoke the build

            Install on the test device, launch, confirm the session resumes.
            """),
            ("Incident Notes.md", """
            # Incident Notes

            ## 2026-09-04 — worker relaunch loop

            The wake sweep only read the flat status key and never the resident
            site's, so it relaunched a cloud worker roughly every two and a half
            minutes for twelve hours before anyone noticed.

            **Fix:** read both keys, prefer the resident site when it is live.

            **Lesson:** a loop that costs money needs an alarm, not a log line.
            """),
            ("Scratch.md", """
            # Scratch

            - Ask Fin to summarize what the build box did overnight
            - Check whether the memory profile picked up the tmux layout
            - Move the eval corpus into the repo proper
            """),
        ]
        for (name, body) in fixtures {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? body.write(to: url, atomically: true, encoding: .utf8)
            guard let bookmark = try? url.fin_markdownBookmarkData() else { continue }
            context.insert(MarkdownDocument(name: name, bookmarkData: bookmark))
        }
    }
    #endif
}
