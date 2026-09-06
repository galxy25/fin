import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore

/// The daemon's half of the send-keys guard. `TmuxCommandGuardTests` proves the policy;
/// this proves the SHIPPED daemon derives it and tells the model about it — the gap that
/// let the previous version's README claim a guarantee the running code did not have.
///
/// `Daemon.run()` is an un-unit-testable async loop, so the two seams it uses are tested
/// directly: `TmuxSendGuard.forHost` (what arms the guard, from the same `connectCommand`
/// the installer writes) and `Daemon.composedSystemPrompt(…tmuxGuard:)` (what the model
/// is told). If either regresses, production runs unguarded or silently guarded.
final class DaemonTmuxGuardPromptTests: XCTestCase {

    private func registryURL(sessions: [String] = []) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-agentd-tmuxguard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(RegistryDocument.standardFileName)
        if !sessions.isEmpty {
            let document = RegistryDocument(sessions: sessions.map { SessionRegistration(session: $0) })
            try JSONEncoder().encode(document).write(to: url)
        }
        return url
    }

    /// The resident-site posture the installer actually writes: a tmux `connectCommand`
    /// and a registry. Both halves of the allow-list have to survive the trip.
    func testGuardArmsFromTheShippedResidentSiteShape() throws {
        let url = try registryURL(sessions: ["fin", "pocketdj"])
        let guardPolicy = TmuxSendGuard.forHost(
            connectCommand: "tmux new-session -A -s fin",
            registryFileURL: url
        )
        XCTAssertTrue(guardPolicy.isEnforced)
        XCTAssertEqual(guardPolicy.resolved().allowed, ["fin", "pocketdj"])
        XCTAssertTrue(guardPolicy.evaluate("tmux send-keys -t main 'rm -rf ~' Enter").isRefusal)
        XCTAssertEqual(guardPolicy.evaluate("tmux capture-pane -p -t main"), .allow)
        XCTAssertEqual(guardPolicy.evaluate("tmux send-keys -t pocketdj 'git status' Enter"), .allow)
    }

    /// Told, not just enforced: an armed guard appends its paragraph, and it names the
    /// read path, the allow-list, and the namespace the model may create sessions in.
    func testArmedGuardAppendsItsParagraphToTheSystemPrompt() throws {
        let registry = try registryURL(sessions: ["fin"])
        let guardPolicy = TmuxSendGuard.forHost(
            connectCommand: "tmux new-session -A -s fin",
            registryFileURL: registry
        )
        let prompt = Daemon.composedSystemPrompt(
            base: Daemon.defaultSystemPrompt,
            registryFileURL: registry,
            tmuxGuard: guardPolicy
        )
        XCTAssertTrue(prompt.hasPrefix(Daemon.defaultSystemPrompt), "the guard section is additive")
        XCTAssertTrue(prompt.contains("tmux guard"), "got: \(prompt)")
        XCTAssertTrue(prompt.contains("capture-pane"))
        XCTAssertTrue(prompt.contains(TmuxCommandGuard.ownedSessionPrefix))
        XCTAssertTrue(prompt.contains("Sessions you may act on: fin"))
    }

    /// The default parameter is `.unenforced`, so a caller that forgets the argument must
    /// produce a byte-identical prompt — an omission can change nothing.
    func testUnarmedGuardLeavesTheSystemPromptByteIdentical() throws {
        let registry = try registryURL()
        let base = Daemon.composedSystemPrompt(
            base: Daemon.defaultSystemPrompt,
            registryFileURL: registry
        )
        let explicit = Daemon.composedSystemPrompt(
            base: Daemon.defaultSystemPrompt,
            registryFileURL: registry,
            tmuxGuard: .unenforced
        )
        XCTAssertEqual(base, Daemon.defaultSystemPrompt)
        XCTAssertEqual(explicit, base)
        XCTAssertFalse(base.contains("tmux guard"))
    }

    /// A host with no tmux session and no registry has no namespace to defend: the guard
    /// stays off, and nothing about the prompt changes. This is also the fail-closed
    /// boundary — `forHost` must not arm with a nil own session and an empty allow-list.
    func testHostWithNeitherTmuxNorRegistryStaysUnarmed() throws {
        let guardPolicy = TmuxSendGuard.forHost(
            connectCommand: "bash -l",
            registryFileURL: try registryURL()
        )
        XCTAssertFalse(guardPolicy.isEnforced)
        XCTAssertNil(guardPolicy.promptSection)
    }
}
