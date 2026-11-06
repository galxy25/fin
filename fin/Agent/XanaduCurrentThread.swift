import Foundation

/// docs/XANADU.md "The current thread": the thread Xanadu is showing, per
/// agent, shared with the App Intents. Rules:
///
/// - Opening a thread anywhere in the app makes it current
///   (`ThreadStore.select(byUser:)` is the one choke point every thread view
///   goes through, so it records the choice there).
/// - A message sent from Xanadu or by a Siri intent WITHOUT an explicit thread
///   goes into the current thread (a follow-up), unless the user asked for a
///   new thread (Xanadu's "new thread" button, `StartFinThreadIntent`).
/// - A brand-new thread's id is its root message id, so the sender knows it
///   the moment the send returns and makes it current.
///
/// Storage: the spec says "App Group defaults". Fin has no App Group today and
/// every intent runs in the app's own process (no Intents extension — see
/// `FinSharedState`), so the app's standard defaults ARE the shared store. The
/// one `defaults` seam is where a group suite goes the day an extension needs
/// it. Keyed by agent NAME, the control plane's identity for an agent (the
/// intents and `ThreadStore` both have it; neither always has the UUID).
enum XanaduCurrentThread {
    static let defaultsKey = "xanadu.currentThreadByAgent"
    /// Posted (object: agent name) whenever an agent's current thread changes,
    /// so a visible Xanadu follows a Siri send or a thread opened elsewhere.
    static let changedNotification = Notification.Name("fin.xanadu.currentThreadChanged")

    /// Unit tests run inside the app's process on macOS — never let them
    /// overwrite the real current thread of whoever runs the suite.
    nonisolated(unsafe) static var defaults: UserDefaults = TestHost.isUnitTest
        ? (UserDefaults(suiteName: "dev.levischoen.fin.tests.xanadu") ?? .standard)
        : .standard

    private static func normalized(_ agent: String) -> String {
        agent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func get(agent: String) -> String? {
        let map = defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        let value = map[normalized(agent)]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    /// nil clears it: the next send without an explicit thread roots a new one.
    static func set(_ threadID: String?, agent: String) {
        let name = normalized(agent)
        guard !name.isEmpty else { return }
        var map = defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        let value = threadID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = value?.isEmpty == false ? value : nil
        guard map[name] != next else { return }
        map[name] = next
        defaults.set(map, forKey: defaultsKey)
        NotificationCenter.default.post(name: changedNotification, object: name)
    }

    /// The thread a send joins. Pure: an explicit thread always wins; a new-
    /// thread request roots one (nil); otherwise the current thread, or a new
    /// root when there is none yet.
    static func target(explicit: String?, startNewThread: Bool, current: String?) -> String? {
        if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty { return explicit }
        if startNewThread { return nil }
        guard let current = current?.trimmingCharacters(in: .whitespacesAndNewlines), !current.isEmpty else { return nil }
        return current
    }

    static func target(explicit: String?, startNewThread: Bool, agent: String) -> String? {
        target(explicit: explicit, startNewThread: startNewThread, current: get(agent: agent))
    }

    /// The thread a message landed in once its send succeeded. Pure: the
    /// control plane's answer when there is one (it is the authority), else the
    /// thread it was sent into, else — a root — its own id.
    static func threadAfterSend(messageID: String, sentThreadID: String?, row: ControlPlaneClient.Message?) -> String {
        if let row { return row.resolvedThreadID }
        if let sent = sentThreadID?.trimmingCharacters(in: .whitespacesAndNewlines), !sent.isEmpty { return sent }
        return messageID
    }

    /// Record a successful send: the thread it landed in becomes current.
    @discardableResult
    static func adoptSend(messageID: String, sentThreadID: String?, row: ControlPlaneClient.Message?, agent: String) -> String {
        let thread = threadAfterSend(messageID: messageID, sentThreadID: sentThreadID, row: row)
        set(thread, agent: agent)
        return thread
    }
}
