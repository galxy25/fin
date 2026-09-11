import Foundation

/// Shared "make a tool call's raw JSON readable" helper for the trace/console
/// drill-down UI (`AgentLogView`'s `TraceRow`, `AgentConsoleView`'s tool-call row) —
/// both surface the same raw arguments string, so the formatting lives in one place.
enum ToolCallFormatting {
    /// Pretty-prints `raw` if it parses as JSON; returns it unchanged otherwise (a
    /// malformed or non-object payload still deserves to be shown, not hidden) so
    /// there's always something sensible behind the disclosure.
    static func prettyPrinted(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys]
              ),
              let string = String(data: pretty, encoding: .utf8)
        else {
            return raw
        }
        return string
    }
}
