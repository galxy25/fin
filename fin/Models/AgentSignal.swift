import Foundation
import SwiftData

/// What a cross-device signal is announcing. Raw values are the wire format (the
/// synced `kind` string and the CloudKit subscription predicate), so they must
/// stay stable across builds.
enum AgentSignalKind: String, CaseIterable {
    case inputRequested
    case turnFinished
    case attention
    case monitoringPaused

    /// Push-alert title, fixed per kind at subscription-creation time — one
    /// `CKQuerySubscription` per kind is what lets a static subscription carry a
    /// kind-specific title at all.
    var pushTitle: String {
        switch self {
        case .inputRequested: return "Fin needs your input"
        case .turnFinished: return "Fin finished a task"
        case .attention: return "Fin needs attention"
        case .monitoringPaused: return "Monitoring paused"
        }
    }
}

/// One cross-device notification event, synced through the private CloudKit
/// database so every *other* device can be push-notified about it (see
/// `AgentSignalSubscriber` — the origin device already showed a local banner,
/// and CloudKit never pushes a fired subscription to the device that made the
/// originating change, so it is excluded server-side).
///
/// The preview passes `MemoryRedactor` and is hard-capped at 140 characters
/// before it ever reaches this model: unlike the local banner, this string
/// leaves the device. Rows are ephemeral by design — a 7-day launch sweep
/// (`AgentRelayApplier.sweepExpiredCrossDeviceRecords`) deletes old ones.
///
/// Every property carries a default and none are unique — required for the
/// CloudKit-mirrored store this model lives in (see `FinApp.init`).
@Model
final class AgentSignal {
    var id: UUID = UUID()
    var agentID: UUID = UUID()
    var agentName: String = ""
    /// `AgentSignalKind` raw value; a string so an older build can still store a
    /// kind it doesn't know.
    var kind: String = ""
    /// Redacted, ≤140-character excerpt of the reply/question/message.
    var preview: String = ""
    /// `DeviceIdentity.short` of the device that produced the signal. No longer
    /// part of any subscription predicate (CloudKit's own originator exclusion
    /// covers origin suppression) — still written on every row for audit.
    var sourceDeviceID8: String = ""
    var createdAt: Date = Date()

    init(agentID: UUID, agentName: String, kind: AgentSignalKind, preview: String, sourceDeviceID8: String) {
        self.id = UUID()
        self.agentID = agentID
        self.agentName = agentName
        self.kind = kind.rawValue
        self.preview = preview
        self.sourceDeviceID8 = sourceDeviceID8
        self.createdAt = Date()
    }
}
