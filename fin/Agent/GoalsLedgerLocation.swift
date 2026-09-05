import Foundation

/// Where THIS device keeps its goals ledger:
/// `Application Support/fin/goals-ledger.json`.
///
/// Same directory convention as `RoutingRegistryLocation`, same shared basename as
/// fin-agentd (which keeps its copy next to its audit log) — one schema pointer covers
/// both readers. Unlike the routing registry the ledger is not machine-scoped in
/// principle: goals belong to the user, not to a host, and the design lane
/// (evals/goals-ledger/README.md) syncs it like `AgentMemory` records, through
/// `MemoryRedactor`. Until that lands, each device reads its local file.
///
/// Nothing in the app creates this file. Absent → `LedgerDocument.loadIfPresent`
/// returns nil, which keeps the system prompt byte-identical to a build without goals
/// AND leaves the heartbeat's reflective text untouched; the tick's ingest path (via
/// `GoalsLedgerStore`) is what brings it into existence.
enum GoalsLedgerLocation {
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fin", isDirectory: true)
            .appendingPathComponent(LedgerDocument.standardFileName)
    }
}
