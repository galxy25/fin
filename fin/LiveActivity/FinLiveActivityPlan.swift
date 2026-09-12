import Foundation

/// The pure half of the attention tile (design §3.4): what the Live Activity
/// should say for a given `FinPresence`, and whether that means start, update,
/// end, or nothing. No ActivityKit here — this compiles and is tested on every
/// platform; `FinLiveActivityController` (iOS only) is the thin shell that
/// hands these decisions to ActivityKit.
enum FinLiveActivityPlan {
    /// Ended this long after Fin stops needing attention (idle / asleep /
    /// answered). Long enough that a quick "working → idle → working" flap
    /// between two heartbeats updates one tile instead of ending and starting.
    static let quietGrace: TimeInterval = 120

    /// The tile text is `FinPresence`'s own headline / detail / glyph,
    /// verbatim — one vocabulary for the console header, the servers list,
    /// and the car screen.
    static func contentState(for presence: FinPresence, now: Date) -> FinActivityAttributes.ContentState {
        let status: FinActivityAttributes.ContentState.Status
        switch presence {
        case .needsInput: status = .needsInput
        case .working: status = .working
        case .idle, .asleep: status = .idle
        }
        return FinActivityAttributes.ContentState(
            headline: presence.headline,
            detail: presence.detail,
            glyph: presence.glyph,
            status: status,
            updatedAt: now.timeIntervalSince1970
        )
    }

    /// Whether this presence is worth a tile at all. Idle and asleep are
    /// not: a Live Activity that says "Fin is ready" for hours is noise in
    /// the Dynamic Island and on the car screen alike.
    static func wantsAttention(_ presence: FinPresence) -> Bool {
        switch presence {
        case .needsInput, .working: return true
        case .idle, .asleep: return false
        }
    }

    enum Action: Equatable {
        case start(FinActivityAttributes.ContentState)
        case update(FinActivityAttributes.ContentState)
        case end(FinActivityAttributes.ContentState)
        case nothing
    }

    /// The local decision loop's memory. Fed one presence sample per poll.
    struct Tracker: Equatable {
        /// True while an activity this device knows about is live — whether
        /// it started it or discovered one the control plane started by push.
        var isRunning = false
        /// The last state applied, so a repeated sample updates nothing.
        var lastState: FinActivityAttributes.ContentState?
        /// When the presence first went quiet while an activity was running.
        var quietSince: Date?

        init(isRunning: Bool = false, lastState: FinActivityAttributes.ContentState? = nil, quietSince: Date? = nil) {
            self.isRunning = isRunning
            self.lastState = lastState
            self.quietSince = quietSince
        }

        mutating func step(_ presence: FinPresence, now: Date) -> Action {
            let next = FinLiveActivityPlan.contentState(for: presence, now: now)
            if FinLiveActivityPlan.wantsAttention(presence) {
                quietSince = nil
                if !isRunning {
                    isRunning = true
                    lastState = next
                    return .start(next)
                }
                if let lastState, lastState.sameContent(as: next) { return .nothing }
                lastState = next
                return .update(next)
            }
            guard isRunning else { return .nothing }
            if let since = quietSince {
                if now.timeIntervalSince(since) >= FinLiveActivityPlan.quietGrace {
                    isRunning = false
                    lastState = nil
                    quietSince = nil
                    return .end(next)
                }
                return .nothing
            }
            quietSince = now
            // A reply the control plane already showed ("Fin answered") stays
            // on the tile through the grace period; anything else becomes the
            // idle headline so the car screen never claims work that is over.
            if let lastState, lastState.status == .answered { return .nothing }
            lastState = next
            return .update(next)
        }

        /// The activity ended or was dismissed outside this loop (the user
        /// swiped it away, the control plane pushed `end`, the system timed
        /// it out).
        mutating func activityEnded() {
            isRunning = false
            lastState = nil
            quietSince = nil
        }
    }
}

extension FinActivityAttributes.ContentState {
    /// Equality that ignores the timestamp: two samples ten seconds apart that
    /// say the same thing are one tile, not two updates.
    func sameContent(as other: FinActivityAttributes.ContentState) -> Bool {
        headline == other.headline && detail == other.detail && glyph == other.glyph && status == other.status
    }
}
