import Foundation
import SwiftData

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
/// Deliberately additive and idempotent: it only inserts when the store is empty of
/// the thing it is about to add, so re-running a capture against a warm simulator
/// doesn't stack duplicates.
enum ScreenshotFixtures {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["FIN_SCREENSHOT_MODE"] == "1"
    }

    /// Hosts are RFC 5737 / RFC 3849 documentation addresses and example.com
    /// subdomains on purpose: a screenshot is a public artifact, and a real
    /// reachable host or tailnet name in one is an information leak that outlives
    /// the release it shipped with.
    static func seedIfNeeded(_ context: ModelContext) {
        guard isEnabled else { return }
        seedServers(context)
        seedAgents(context)
        seedDocuments(context)
        try? context.save()
    }

    private static func seedServers(_ context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<Server>())) ?? []
        guard existing.isEmpty else { return }
        let servers = [
            Server(
                name: "Studio iMac",
                host: "studio.example.com",
                username: "levi",
                tmuxSessionName: "fin"
            ),
            Server(
                name: "Build Box",
                host: "build.example.com",
                username: "ci",
                tmuxSessionName: "ci"
            ),
            Server(
                name: "Cloud Worker",
                host: "worker.example.com",
                username: "ubuntu",
                tmuxSessionName: "agent"
            ),
        ]
        for server in servers {
            context.insert(server)
        }
    }

    private static func seedAgents(_ context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<Agent>())) ?? []
        guard existing.isEmpty else { return }
        // "Fin" is seeded here rather than left to
        // `AgentListView.seedDefaultAgentIfNeeded`: that one only fires when the
        // agent list is empty, and inserting any fixture agent first would
        // suppress it — leaving a capture whose Agents tab is missing the very
        // agent the product is named after.
        context.insert(
            Agent(
                name: "Fin",
                provider: .appleOnDevice,
                contextWindowTokens: 8192,
                defaultMode: .manual
            )
        )
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
    }

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
}
