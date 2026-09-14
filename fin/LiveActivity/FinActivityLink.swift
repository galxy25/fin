import Foundation

/// The URL a tap on the attention tile opens (docs/CARPLAY-IMESSAGE-DESIGN.md
/// §3.4). Compiled into the app (which handles it in `finApp`'s `onOpenURL`)
/// and the fin-widgets extension (which attaches it with `widgetURL`), so the
/// two agree on the one scheme: `fin://open?agent=<name>[&thread=<m-id>]`.
///
/// Levi (2026-09-13): tapping "Fin needs your input" opened the last terminal
/// session, not the question — the tile had no link at all. Now it names the
/// agent and, when the control plane knows it, the thread the question rooted
/// (`ContentState.threadID`), which the app opens exactly like a notification
/// tap on that thread.
enum FinActivityLink {
    static let scheme = "fin"
    static let host = "open"

    struct Target: Equatable {
        var agentName: String
        var threadID: String?
    }

    static func url(agentName: String, threadID: String?) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        var items = [URLQueryItem(name: "agent", value: agentName)]
        if let threadID, !threadID.isEmpty {
            items.append(URLQueryItem(name: "thread", value: threadID))
        }
        components.queryItems = items
        return components.url
    }

    /// nil for any URL that is not ours or names no agent.
    static func target(of url: URL) -> Target? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String) -> String? {
            let raw = items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw?.isEmpty ?? true) ? nil : raw
        }
        guard let agent = value("agent") else { return nil }
        return Target(agentName: agent, threadID: value("thread"))
    }
}
