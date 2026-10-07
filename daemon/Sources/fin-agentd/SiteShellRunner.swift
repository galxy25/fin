import Foundation

/// The `run-shell` site command: run one operator-supplied shell command on this
/// site and report what it printed. Operator-only by construction — the control
/// plane's `POST /sites/{id}/commands` does NOT accept this kind (see
/// `SITE_COMMAND_KINDS` in lambda.py), so the only way to queue one is a direct
/// write to the `fin-sites` row with AWS admin credentials
/// (`scripts/cloud-agent/control-plane/queue-site-command.py`). An app user's
/// token can never reach it.
enum SiteShellRunner {
    struct Outcome: Equatable {
        var exitCode: Int32
        var timedOut: Bool
        var output: String
        var truncated: Bool
    }

    static let defaultTimeoutSeconds = 300
    static let maxTimeoutSeconds = 1800
    /// Output kept for the audit line / log file; the tail is what matters on failure.
    static let outputCapBytes = 64 * 1024

    /// A launchd job's PATH is `/usr/bin:/bin:/usr/sbin:/sbin`, which has neither
    /// Homebrew nor a user's own tools — the commands an operator queues assume both.
    static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
        let existing = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        env["PATH"] = (extra.filter { !existing.contains($0) } + existing).joined(separator: ":")
        return env
    }

    static func timeout(from raw: String?) -> Int {
        guard let raw, let value = Int(raw), value > 0 else { return defaultTimeoutSeconds }
        return min(value, maxTimeoutSeconds)
    }

    /// Runs `command` under `/bin/sh -c`, merging stdout and stderr, killing it at
    /// `timeoutSeconds`. Never throws: a launch failure is an Outcome with exit 127.
    static func run(command: String, timeoutSeconds: Int, environment: [String: String] = environment()) async -> Outcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", command]
                process.environment = environment
                process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: Outcome(
                        exitCode: 127, timedOut: false,
                        output: "failed to launch /bin/sh: \(error.localizedDescription)", truncated: false))
                    return
                }
                let timedOut = Locked(false)
                let timer = DispatchWorkItem {
                    timedOut.set(true)
                    process.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timer)
                // Read to EOF BEFORE waiting: a child that fills the pipe buffer blocks
                // forever if nobody drains it.
                var data = Data()
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    data.append(chunk)
                    if data.count > outputCapBytes * 4 { data = data.suffix(outputCapBytes * 2) }
                }
                process.waitUntilExit()
                timer.cancel()
                let (text, truncated) = tail(data)
                continuation.resume(returning: Outcome(
                    exitCode: process.terminationStatus, timedOut: timedOut.get(),
                    output: text, truncated: truncated))
            }
        }
    }

    static func tail(_ data: Data) -> (String, Bool) {
        let truncated = data.count > outputCapBytes
        let slice = truncated ? data.suffix(outputCapBytes) : data
        return (String(decoding: slice, as: UTF8.self), truncated)
    }

    /// The audit/log rendering: a one-line header, then the output.
    static func report(id: String, command: String, outcome: Outcome) -> String {
        var status = outcome.timedOut ? "TIMED OUT" : "exit \(outcome.exitCode)"
        if outcome.truncated { status += " (output truncated to last \(outputCapBytes / 1024) KB)" }
        return "[site] run-shell \(id): \(status)\n$ \(command.prefix(500))\n\(outcome.output)"
    }

    private final class Locked<T>: @unchecked Sendable {
        private var value: T
        private let lock = NSLock()
        init(_ value: T) { self.value = value }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
    }
}
