import Foundation
#if os(iOS)
import ActivityKit
#endif

/// The Live Activity's identity and state — docs/CARPLAY-IMESSAGE-DESIGN.md
/// §3.4, the Phase-2 "attention tile". Compiled into BOTH the app (which
/// starts/updates the activity) and the fin-widgets extension (which renders
/// it), so the two agree byte-for-byte on the JSON ActivityKit passes between
/// them and on the `content-state` the control plane pushes.
///
/// A plain Codable struct on every platform; the `ActivityAttributes`
/// conformance is added only where ActivityKit exists (iOS — the macOS SDK
/// ships the framework but marks the protocol unavailable, and visionOS has no
/// framework at all).
///
/// Wire contract with the Lambda (`_activity_content_state`): keys are these
/// property names verbatim, `status` is one of the raw values below, and
/// `updatedAt` is Unix epoch SECONDS as a number — deliberately not a `Date`,
/// because ActivityKit decodes a pushed `content-state` with a plain
/// JSONDecoder whose date strategy is not ours to choose.
struct FinActivityAttributes: Codable, Hashable {
    /// The agent's display name ("Fin") — the tile's title on the Lock Screen.
    var agentName: String
    /// The agent's UUID string, or "" when the sender (a site heartbeat)
    /// only knows the name. Carried so a future tap target can deep-link.
    var agentID: String

    struct ContentState: Codable, Hashable {
        enum Status: String, Codable, Hashable {
            case working
            case needsInput
            case idle
            case answered
        }

        /// "Fin is working" / "Fin needs your input" — `FinPresence.headline`
        /// verbatim, or "Fin answered" for a reply push.
        var headline: String
        /// "on Levi's iMac", or the reply preview; nil when there is nothing to add.
        var detail: String?
        /// SF Symbol name (`FinPresence.glyph`).
        var glyph: String
        var status: Status
        /// Unix epoch seconds.
        var updatedAt: Double
    }
}

#if os(iOS)
@available(iOS 16.1, *)
extension FinActivityAttributes: ActivityAttributes {}
#endif
