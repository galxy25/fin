import Foundation

/// Where THIS device keeps its session-routing registry:
/// `Application Support/fin/routing-registry.json`.
///
/// Machine-scoped on purpose: the registry names tmux sessions, and a tmux session
/// exists on exactly one machine — syncing the file (the CloudKit store, the iCloud
/// Drive mirror) would teach every other device to route terminal work into sessions
/// it cannot reach. Application Support is the app's convention for exactly this kind
/// of per-device file (see `VectorMemoryIndexManager.defaultDirectory`); the basename
/// is shared with fin-agentd so one schema pointer covers both readers.
///
/// Nothing in the app creates this file. Absent → `RegistryDocument.loadIfPresent`
/// returns nil and the system prompt stays byte-identical to a build without routing;
/// registering a session (a future write path via `SessionRoutingRegistry`) is what
/// brings it into existence.
enum RoutingRegistryLocation {
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fin", isDirectory: true)
            .appendingPathComponent(RegistryDocument.standardFileName)
    }
}
