import Foundation

// Foundation-only (no SwiftUI) so the fin-tv target compiles it too: the TV's
// transcript strips the same "[Attached: …]" line (project.yml).

/// Pure text helpers for how Xanadu renders a transcript line.
enum XanaduText {
    /// The daemon records a turn with attachments as its text plus a trailing
    /// `[Attached: <name> (<kind>, <size>), …]` line (a files-only message is
    /// that line alone) — user turns, and since "Fin replies with files" Fin's
    /// replies too. The chips come from the message row (`attachments` /
    /// `replyAttachments`), so the line is dropped from the text everywhere it
    /// renders (Xanadu, the remote console, tvOS); an older prompt-style
    /// "Attached files (saved on this machine…" block is dropped the same way.
    static func displayText(_ text: String) -> String {
        var result = text
        if let marker = result.range(of: "Attached files (saved on this machine") {
            result = String(result[..<marker.lowerBound])
        }
        var lines = result.components(separatedBy: "\n")
        while let last = lines.last {
            let trimmed = last.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || (trimmed.hasPrefix("[Attached:") && trimmed.hasSuffix("]")) {
                lines.removeLast()
            } else {
                break
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `fin://thread?id=<m-…>` — a thread mention in a message links here.
    static func threadLink(_ threadID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "fin"
        components.host = "thread"
        components.queryItems = [URLQueryItem(name: "id", value: threadID)]
        return components.url
    }

    static func threadID(fromLink url: URL) -> String? {
        guard url.scheme?.lowercased() == "fin", url.host?.lowercased() == "thread" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
    }

    private static let threadMention = try? NSRegularExpression(
        pattern: #"\bm-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#
    )
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Every link in a message, as (range, url): web links from the data
    /// detector, thread ids as `fin://thread` links. Pure.
    static func links(in text: String) -> [(range: NSRange, url: URL)] {
        let whole = NSRange(text.startIndex..., in: text)
        var found: [(NSRange, URL)] = []
        linkDetector?.enumerateMatches(in: text, range: whole) { match, _, _ in
            guard let match, let url = match.url, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }
            found.append((match.range, url))
        }
        threadMention?.enumerateMatches(in: text, range: whole) { match, _, _ in
            guard let match, let range = Range(match.range, in: text), let url = threadLink(String(text[range])) else { return }
            guard !found.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) else { return }
            found.append((match.range, url))
        }
        return found.sorted { $0.0.location < $1.0.location }
    }

    /// Markdown (inline) when it parses, then every bare link made tappable.
    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let plain = String(attributed.characters)
        for (range, url) in links(in: plain) {
            guard let span = Range<AttributedString.Index>(range, in: attributed) else { continue }
            if attributed[span].link == nil { attributed[span].link = url }
        }
        return attributed
    }
}
