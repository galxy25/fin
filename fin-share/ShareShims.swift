import Foundation

// fin-share compiles a handful of the app's own files (project.yml) — the
// upload-then-send flow, the control-plane client, the current thread — so a
// share goes over exactly the code path Xanadu uses. Those files name a few
// app types the extension has no business compiling (SwiftData, CloudKit, the
// sites directory). These are the extension's stand-ins: same names, backed
// by what the app mirrored into the App Group (`FinShareMirror`). Nothing here
// is compiled into the app.

/// Read once per share: what the app last mirrored.
enum ShareCredentials {
    static let snapshot: FinShareMirror.Snapshot? = FinShareMirror.read(from: .live)
}

/// `ControlPlaneClient`'s config, from the mirror instead of iCloud KVS and
/// the app's synced keychain item.
enum CloudControlPlaneConfig {
    static var endpointURL: String { ShareCredentials.snapshot?.endpointURL ?? "" }
    static var token: String { ShareCredentials.snapshot?.token ?? "" }
    static var isConfigured: Bool { !endpointURL.isEmpty && !token.isEmpty }
}

/// The app's install id, so a shared message reads as sent from this device
/// (the extension's own defaults would mint a different one).
enum DeviceIdentity {
    static var short: String {
        let mirrored = ShareCredentials.snapshot?.deviceID8 ?? ""
        return mirrored.isEmpty ? String(fallback.prefix(8)) : mirrored
    }
    private static let fallback = UUID().uuidString.lowercased()
}

enum CloudAgentChannel {
    static var maxTextLength: Int { ShareIntake.messageTextLimit }
}

enum TestHost {
    static let isUnitTest = false
}

/// `ControlPlaneClient.listSites` decodes these; the extension never calls it.
struct FinSite: Decodable, Equatable {}
