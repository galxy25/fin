import XCTest
import SwiftData
@testable import fin

/// One-shot utility, not a test of app behavior: forces CloudKit to create the
/// Development-environment schema for newly added synced models.
///
/// SwiftData's CloudKit mirror creates a record type lazily, on the first real export of
/// an instance — which the normal suites never do (they run against in-memory stores) and
/// the app only does once a user exercises the feature. Shipping a TestFlight build whose
/// schema was never created-then-promoted means Production sync silently fails forever;
/// that exact trap cost days of "stuck syncing" once already. Run this deliberately after
/// adding a synced model, then promote via the CloudKit Console:
///
///   TEST_RUNNER_FIN_SEED_CLOUDKIT_SCHEMA=1 xcodebuild test -scheme fin \
///     -destination 'platform=macOS' -only-testing:finTests/CloudKitSchemaSeedTests
///
/// (The TEST_RUNNER_ prefix is how xcodebuild forwards an environment variable into the
/// test process; without it the guard below sees nothing and skips.)
///
/// Uses a throwaway store file so the app's real store is never touched; the one seeded
/// record lands in the Development environment only (never Production) and is deleted
/// from the store afterward regardless.
final class CloudKitSchemaSeedTests: XCTestCase {

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["FIN_SEED_CLOUDKIT_SCHEMA"] == "1" else {
            throw XCTSkip("Schema seeding runs only when FIN_SEED_CLOUDKIT_SCHEMA=1.")
        }
    }

    @MainActor
    func testSeedDevelopmentSchemaForSyncedModels() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-schema-seed-\(UUID().uuidString).store")
        let seedSchema = Schema([
            Server.self, KeyMetadata.self, Agent.self, AgentMemory.self,
            AgentSignal.self, AgentRelayMessage.self,
        ])
        let config = ModelConfiguration(
            "SchemaSeed",
            schema: seedSchema,
            url: storeURL,
            cloudKitDatabase: .private("iCloud.dev.levischoen.fin")
        )
        let container = try ModelContainer(for: seedSchema, configurations: [config])
        let context = container.mainContext

        let memorySeed = AgentMemory(
            kind: .episodic,
            agentID: nil,
            conversationID: nil,
            title: "schema seed",
            content: "Throwaway record that exists only to make CloudKit create CD_AgentMemory.",
            tags: "schema-seed"
        )
        // Cross-device models: one instance each so CloudKit creates CD_AgentSignal
        // and CD_AgentRelayMessage in the Development environment. (After seeding,
        // the CloudKit Console still needs a QUERYABLE index added by hand on
        // CD_AgentSignal.CD_kind for the push subscription's predicate — and
        // eventually a Production promotion. CD_sourceDeviceID8 no longer needs
        // one: the user-level subscriptions dropped it from the predicate, though
        // the field is still written for audit.)
        let signalSeed = AgentSignal(
            agentID: UUID(),
            agentName: "schema seed",
            kind: .attention,
            preview: "Throwaway record that exists only to make CloudKit create CD_AgentSignal.",
            sourceDeviceID8: "seed0000"
        )
        let relaySeed = AgentRelayMessage(
            agentID: UUID(),
            text: "Throwaway record that exists only to make CloudKit create CD_AgentRelayMessage.",
            authorDeviceID8: "seed0000"
        )
        // CloudKit only materializes NEW FIELDS on existing types when a record
        // carrying them exports — field additions to Agent (live outage: build 31's
        // heartbeatDefaultUpgraded never reached CD_Agent, and the zone's atomic
        // export commit then blocked EVERY record type on every device) need a
        // throwaway Agent here, not just the newer standalone models.
        let agentSeed = Agent(name: "schema seed (deleted automatically)")
        context.insert(memorySeed)
        context.insert(signalSeed)
        context.insert(relaySeed)
        context.insert(agentSeed)
        try context.save()

        // The mirror batches exports; give it long enough to actually reach CloudKit.
        // There is no completion signal to await here — the CloudKit Console's
        // Development record types list is the ground truth to check afterward.
        try await Task.sleep(for: .seconds(20))

        context.delete(memorySeed)
        context.delete(signalSeed)
        context.delete(relaySeed)
        context.delete(agentSeed)
        try context.save()
        try? await Task.sleep(for: .seconds(5))
    }
}
