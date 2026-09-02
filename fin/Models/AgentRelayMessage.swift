import Foundation
import SwiftData

/// A user message typed on a device that does NOT host the agent's live runtime,
/// synced through the private CloudKit database so whichever device does host it
/// can inject the message through the exact same `submit` path a locally-typed
/// message takes (see `AgentRelayApplier`). `appliedAt`/`appliedByDeviceID8` sync
/// back, which is how the sender's remote console flips "sending…" to "sent".
///
/// Every property carries a default and none are unique — required for the
/// CloudKit-mirrored store this model lives in (see `FinApp.init`). Rows are
/// ephemeral: the launch sweep deletes applied rows after 7 days and unapplied
/// rows after a 30-day hard floor (see `AgentRelayApplier`'s retention
/// constants; the sender UI shows a row past the floor as "expired").
@Model
final class AgentRelayMessage {
    var id: UUID = UUID()
    var agentID: UUID = UUID()
    var text: String = ""
    /// `DeviceIdentity.short` of the device the message was typed on.
    var authorDeviceID8: String = ""
    var createdAt: Date = Date()
    /// Stamped by the hosting device once the message demonstrably entered its
    /// runtime; nil means still waiting for a device with a live, connected,
    /// non-busy runtime — retried until the sweep's 30-day unapplied floor.
    /// Also stamped for a message resolved WITHOUT injection: then
    /// `appliedByDeviceID8` carries a `rejected:` sentinel instead of a device
    /// id (see `AgentRelayApplier.rejectedLength`).
    var appliedAt: Date? = nil
    var appliedByDeviceID8: String? = nil

    init(agentID: UUID, text: String, authorDeviceID8: String) {
        self.id = UUID()
        self.agentID = agentID
        self.text = text
        self.authorDeviceID8 = authorDeviceID8
        self.createdAt = Date()
    }
}
