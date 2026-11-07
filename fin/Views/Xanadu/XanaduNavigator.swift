import Foundation

/// How anything outside the view tree — an App Intent that opens the app, a
/// search handed in by Siri — brings Xanadu forward on a given thread. Intents
/// run in the app's process (no extension), so a process-wide object is the
/// bridge: `RootView` routes to Xanadu on every request, and the visible
/// `XanaduView` switches agent / thread to match.
@MainActor
final class XanaduNavigator: ObservableObject {
    static let shared = XanaduNavigator()

    struct Request: Equatable {
        let id = UUID()
        var agentName: String?
        var threadID: String?
    }

    @Published private(set) var request: Request?

    /// Open Xanadu; a named thread becomes the agent's current thread first,
    /// so even a Xanadu that mounts after this call lands on it.
    func open(agentName: String?, threadID: String?) {
        if let agentName, let threadID {
            XanaduCurrentThread.set(threadID, agent: agentName)
        }
        request = Request(agentName: agentName, threadID: threadID)
    }
}
