import Foundation

/// Best-effort scrub applied to every write into the CloudKit-synced memory store.
///
/// Memory content derives from terminal output and model replies — the likeliest place
/// for a server's secrets to appear — so recognizable secret shapes are dropped or
/// masked before persistence. Deliberately pattern-based and conservative: it catches
/// shapes (key material, long tokens, credential assignments), not every possible
/// secret. The residual risk is documented on `AgentMemory`.
///
/// Public for the same reason `AgentTurnLogic` is: fin-agentd's cloud transcript runs
/// every line through this before it leaves the machine.
public enum MemoryRedactor {
    private static let mark = "[redacted]"

    /// PEM armor lines. The base64 body between them is caught by the long-base64 mask,
    /// so dropping the boundaries removes the whole recognizable key block.
    private static let pemBoundary = try! NSRegularExpression(
        pattern: #"-----(BEGIN|END)[A-Z0-9 ]*-----"#
    )

    private static let masks: [(pattern: NSRegularExpression, template: String)] = [
        // A credential-shaped assignment: keep the key, mask the value. The optional
        // quote between key and separator lets JSON-quoted keys ("password": "…")
        // match too — the mirror feeds this raw tool-argument JSON, not just prose.
        (
            try! NSRegularExpression(
                pattern: #"(?i)([\w-]*(?:password|passwd|token|secret|api[_-]?key|apikey|credential)[\w-]*["']?\s*[:=]+\s*)("[^"]*"|'[^']*'|\S+)"#
            ),
            "$1[redacted]"
        ),
        // AWS access key IDs.
        (try! NSRegularExpression(pattern: #"\bAKIA[0-9A-Z]{16}\b"#), mark),
        // Long hex runs — hashes, session tokens, raw key material.
        (try! NSRegularExpression(pattern: #"\b[0-9a-fA-F]{32,}\b"#), mark),
        // Long base64 runs — encoded keys, JWT segments, PEM bodies.
        (try! NSRegularExpression(pattern: #"[A-Za-z0-9+/]{40,}={0,2}"#), mark),
    ]

    public nonisolated static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return text
            .components(separatedBy: "\n")
            .compactMap { line -> String? in
                let range = NSRange(line.startIndex..., in: line)
                guard pemBoundary.firstMatch(in: line, range: range) == nil else { return nil }
                var masked = line
                for (pattern, template) in masks {
                    masked = pattern.stringByReplacingMatches(
                        in: masked,
                        range: NSRange(masked.startIndex..., in: masked),
                        withTemplate: template
                    )
                }
                return masked
            }
            .joined(separator: "\n")
    }
}
