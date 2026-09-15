import XCTest
@testable import FinAgentCore

/// Does a given model actually produce a usable user profile?
///
/// **OPT-IN** (`FIN_LIVE_TESTS=1`), because it drives a real model — see
/// `LiveIntegrationTests.requireLiveOptIn`. This is the harness for the question the
/// daemon could only answer with "model returned unusable text": it builds the REAL
/// instruction and the REAL input through `ProfileCompaction`, sends them to whichever
/// endpoint and model the environment names, and reports exactly why the result would be
/// accepted or rejected.
///
/// It exists because a profile that had been stale for weeks was blamed, in order, on a
/// sync echo, a starved candidate window, and finally on the model — while the store it
/// was distilling turned out to be 27 copies of Fin's own system prompt. Comparing models
/// is only meaningful against clean input, and only if the comparison runs the same code
/// the daemon runs (2026-09-15).
///
///     FIN_LIVE_TESTS=1 \
///     FIN_PROFILE_PATH=/tmp/live-profile.txt \
///     FIN_ENTRIES_PATH=/tmp/live-entries.json \
///     FIN_LLM_MODEL=google/gemma-4-26b-a4b \
///     swift test --package-path daemon --filter ProfileCompactionLiveTests
@MainActor
final class ProfileCompactionLiveTests: XCTestCase {

    private func requireOptIn() throws {
        guard ProcessInfo.processInfo.environment["FIN_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Live tests are opt-in: set FIN_LIVE_TESTS=1.")
        }
    }

    private struct Entry: Decodable {
        let title: String?
        let content: String?
        let updatedAt: String?
    }

    func testTheConfiguredModelProducesAnAcceptableProfile() async throws {
        try requireOptIn()
        let environment = ProcessInfo.processInfo.environment
        guard let profilePath = environment["FIN_PROFILE_PATH"],
              let entriesPath = environment["FIN_ENTRIES_PATH"],
              let currentProfile = try? String(contentsOfFile: profilePath, encoding: .utf8),
              let entriesData = FileManager.default.contents(atPath: entriesPath)
        else {
            throw XCTSkip("Set FIN_PROFILE_PATH and FIN_ENTRIES_PATH to real captured inputs.")
        }
        let endpoint = environment["FIN_LLM_URL"] ?? "http://127.0.0.1:1234/v1"
        let model = environment["FIN_LLM_MODEL"] ?? "google/gemma-4-12b-qat"
        let budget = Int(environment["FIN_LLM_MAX_TOKENS"] ?? "") ?? 2048

        struct Document: Decodable { let entries: [Entry] }
        let entries = (try? JSONDecoder().decode(Document.self, from: entriesData))?.entries ?? []
        let formatter = ISO8601DateFormatter()
        let conversations = entries.map { entry in
            ProfileCompaction.Conversation(
                title: entry.title ?? "",
                date: entry.updatedAt.flatMap { formatter.date(from: $0) } ?? Date(),
                content: entry.content ?? ""
            )
        }

        let instruction = ProfileCompaction.instruction()
        let input = ProfileCompaction.input(
            currentProfile: currentProfile, observed: [],
            conversations: conversations, perConversationCap: 1500
        )

        // A big local model is slower than any interactive default. The client's timeout is
        // a process-wide setting, so raise it here rather than let a 26B model look like a
        // broken endpoint (it timed out at 120s on the first 26B run, 2026-09-15).
        let savedTimeout = AgentEndpointClient.defaultRequestTimeout
        defer { AgentEndpointClient.defaultRequestTimeout = savedTimeout }
        AgentEndpointDefaults.setRequestTimeout(
            seconds: Int(environment["FIN_LLM_TIMEOUT"] ?? "") ?? 1200
        )

        let started = Date()
        let text: String
        do {
            text = try await rawCompletion(
                instruction: instruction, input: input,
                endpointURL: endpoint, model: model, apiKey: environment["FIN_LLM_API_KEY"],
                temperature: 0.2, maxOutputTokens: budget,
                assistantPrefill: ProfileCompaction.assistantPrefill
            )
        } catch {
            XCTFail("\(model): the endpoint failed outright: \(error.localizedDescription)")
            return
        }
        let elapsed = Date().timeIntervalSince(started)
        let trimmed = ProfileCompaction.assembled(from: text)
        let headings = ProfileCompaction.sectionHeadings.filter { trimmed.contains($0) }
        let accepted = ProfileCompaction.acceptable(trimmed, replacing: currentProfile)

        // The whole point is the report, so print it whatever the verdict.
        print("""

        ===== PROFILE COMPACTION: \(model) =====
        endpoint      \(endpoint)   budget \(budget) tokens
        elapsed       \(String(format: "%.1f", elapsed))s
        input         profile \(currentProfile.count) chars + \(conversations.count) conversations
        returned      \(trimmed.count) chars
        headings      \(headings.count)/4 \(headings)
        contains(none) \(trimmed.contains("(none)"))
        ACCEPTED      \(accepted)
        ----- first 600 chars -----
        \(trimmed.prefix(600))
        ===========================================

        """)

        XCTAssertFalse(
            trimmed.isEmpty,
            "\(model) returned NOTHING — with a reasoning model that usually means the output "
                + "budget went entirely on thinking. Raise FIN_LLM_MAX_TOKENS and retry."
        )
        // A profile the model ran out of room to finish is worse than none: it looks
        // structurally sound and becomes the input to the next pass.
        XCTAssertTrue(
            trimmed.contains("**Preferences**"),
            "\(model) stopped before the last section — the reply was cut off at \(trimmed.count) "
                + "chars. Raise the budget (DaemonMemoryConsolidator.compactionOutputTokens)."
        )
        XCTAssertTrue(
            accepted,
            "\(model) produced text the daemon would reject: \(trimmed.count) chars, "
                + "\(headings.count)/4 headings. This is the exact check "
                + "`DaemonMemoryConsolidator` fails with \"model returned unusable text\"."
        )
    }
}
