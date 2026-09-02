import XCTest
import SwiftData
@testable import fin

/// Mirrors the exact `ModelContainer` wiring in `FinApp.init` so schema-level problems
/// (a CloudKit-invalid model, a bad predicate) surface here rather than as a launch crash.
final class AgentPersistenceTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let synced = ModelConfiguration(
            "Synced",
            schema: Schema([Server.self, KeyMetadata.self, Agent.self, AgentMemory.self]),
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let local = ModelConfiguration(
            "Local",
            schema: Schema([Clipping.self, MarkdownDocument.self, AgentLogEntry.self]),
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: Schema([
                Server.self, KeyMetadata.self, Agent.self, AgentMemory.self,
                Clipping.self, MarkdownDocument.self, AgentLogEntry.self,
            ]),
            configurations: [synced, local]
        )
    }

    @MainActor
    func testInsertsAndFetchesAnAgent() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let agent = Agent(name: "Fin", modelIdentifier: "google/gemma-4-12b-qat")
        context.insert(agent)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Agent>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.name, "Fin")
        XCTAssertEqual(fetched.first?.defaultMode, .manual)
    }

    @MainActor
    func testInsertsAndQueriesLogEntriesByAgent() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let agentID = UUID()
        let other = UUID()
        for (index, id) in [agentID, agentID, other].enumerated() {
            context.insert(AgentLogEntry(record: AgentLogRecord(
                agentID: id,
                agentName: "Fin",
                serverName: "box",
                runID: UUID(),
                sequence: index,
                kind: .userMessage,
                text: "hello \(index)"
            )))
        }
        try context.save()

        // The same predicate shape `AgentLogView` builds.
        let descriptor = FetchDescriptor<AgentLogEntry>(
            predicate: #Predicate<AgentLogEntry> { $0.agentID == agentID },
            sortBy: [SortDescriptor(\AgentLogEntry.timestamp, order: .reverse)]
        )
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(fetched.count, 2)
    }

    @MainActor
    func testAgentModeRoundTripsThroughStorage() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let agent = Agent(name: "Auto", defaultMode: .auto)
        context.insert(agent)
        try context.save()

        let fetched = try XCTUnwrap(try context.fetch(FetchDescriptor<Agent>()).first)
        XCTAssertEqual(fetched.defaultMode, .auto)
        fetched.defaultMode = .manual
        try context.save()
        XCTAssertEqual(fetched.defaultModeRaw, AgentMode.manual.rawValue)
    }

    @MainActor
    func testMonitoringArmedRoundTripsThroughStorage() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let agent = Agent(name: "Fin")
        XCTAssertFalse(agent.monitoringArmed)
        XCTAssertEqual(agent.monitoringDeviceID, "")
        XCTAssertNil(agent.monitoringServerID)
        let serverID = UUID()
        agent.monitoringArmed = true
        agent.monitoringDeviceID = "device-a"
        agent.monitoringServerID = serverID
        context.insert(agent)
        try context.save()

        let fetched = try XCTUnwrap(try context.fetch(FetchDescriptor<Agent>()).first)
        XCTAssertTrue(fetched.monitoringArmed)
        XCTAssertEqual(fetched.monitoringDeviceID, "device-a")
        XCTAssertEqual(fetched.monitoringServerID, serverID)
        fetched.disarmMonitoring()
        try context.save()
        XCTAssertFalse(fetched.monitoringArmed)
        XCTAssertEqual(fetched.monitoringDeviceID, "")
        XCTAssertNil(fetched.monitoringServerID)
    }

    @MainActor
    func testAgentMemoryRoundTripsThroughStorage() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let conversationID = UUID()
        let agentID = UUID()
        context.insert(AgentMemory(
            kind: .episodic,
            agentID: agentID,
            conversationID: conversationID,
            title: "Deploy question",
            content: "Q: how do I deploy / A: use the script",
            tags: "auto,conversation"
        ))
        try context.save()

        let fetched = try XCTUnwrap(try context.fetch(FetchDescriptor<AgentMemory>()).first)
        XCTAssertEqual(fetched.kind, .episodic)
        XCTAssertEqual(fetched.agentID, agentID)
        XCTAssertEqual(fetched.conversationID, conversationID)
        XCTAssertEqual(fetched.title, "Deploy question")
        XCTAssertEqual(fetched.tags, "auto,conversation")
        XCTAssertNil(fetched.stoppedAt)
        XCTAssertNil(fetched.consolidatedAt)
    }

    @MainActor
    func testFetchOrCreateCumulativeIsASingleton() throws {
        let container = try makeContainer()
        let store = MemoryStore(context: container.mainContext)

        let first = store.fetchOrCreateCumulative()
        let second = store.fetchOrCreateCumulative()
        XCTAssertEqual(first.id, second.id)

        let kind = MemoryKind.cumulative.rawValue
        let all = try container.mainContext.fetch(
            FetchDescriptor<AgentMemory>(predicate: #Predicate { $0.kindRaw == kind })
        )
        XCTAssertEqual(all.count, 1)
    }

    func testLogEntryProducesValidJSONL() throws {
        let entry = AgentLogEntry(record: AgentLogRecord(
            agentID: UUID(),
            agentName: "Fin",
            serverName: "box",
            runID: UUID(),
            sequence: 1,
            kind: .toolCall,
            text: "ls -la\n",
            toolName: "send_input",
            toolArguments: #"{"input":"ls -la\n"}"#,
            disposition: .approved,
            modelIdentifier: "gemma",
            temperature: 0.2,
            promptTokens: 100,
            completionTokens: 20,
            totalTokens: 120,
            latencyMS: 900,
            timeToFirstTokenMS: 210,
            approvalWaitMS: 4300
        ))

        let line = try XCTUnwrap(entry.jsonlLine())
        let data = try XCTUnwrap(line.data(using: .utf8))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["kind"] as? String, "toolCall")
        XCTAssertEqual(object["disposition"] as? String, "approved")
        let tokens = try XCTUnwrap(object["tokens"] as? [String: Any])
        XCTAssertEqual(tokens["total"] as? Int, 120)
        let timing = try XCTUnwrap(object["timing"] as? [String: Any])
        XCTAssertEqual(timing["ttft_ms"] as? Int, 210)
        XCTAssertEqual(timing["approval_wait_ms"] as? Int, 4300)
    }
}
