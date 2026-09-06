// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation

// WHY THIS FILE IS NOW SMALL, AND WHAT IT IS NO LONGER FOR.
//
// The previous version of this file (≈1580 lines) tried to make `send_input` safe by
// PARSING the model's command string and classifying every tmux subcommand against a
// registry of allowed session names: read anything, write only what is registered.
// Eight independent reviews found thirty-five distinct high-severity bypasses, and each
// fix round produced new ones — quoted `;` separators, getopt clusters, `kill-session -a`
// inverting `-t`, `send-keys -K -c <client-tty>` with no `-t` at all, shell keywords
// before tmux, redirections splitting a simple command, `sh -` reading stdin, inline
// interpreters, heredocs, backslash-newline continuations, quoted program names. That is
// not a buggy implementation. It is evidence that a byte-level parser over an
// adversarially-shaped shell string is the wrong SHAPE of solution.
//
// The boundary is now structural and lives outside this file: the agent's shell runs on
// its OWN tmux socket (`tmux -L fin new-session -A -s fin`, written by
// scripts/mac-fin-agentd/provision-config.sh). `tmux -L` names a socket file, so the
// agent's tmux server is a different process from the one hosting the human's `main`.
// No string the model types inside that shell reaches `main` — not because we classified
// it, but because the server it would have to talk to is not the one its `$TMUX` points
// at. Correctness by topology, not by parsing. The read half that this costs is restored
// structurally too, by the `read_session` tool (`TmuxSessionRead`), which takes a session
// NAME and runs a fixed argv on a separate SSH exec channel.
//
// So this file's job collapsed to a SMALL, PROVABLE rule set. It is a second layer behind
// a real boundary, not the boundary itself:
//
//   R0  NO PROOF, NO TMUX. Every rule below assumes a bare `tmux …` reaches the agent's
//       OWN server — true only because `$TMUX` points there, which is a fact about a
//       connectCommand typed into a PTY and can fail quietly. The daemon asks the live
//       shell for `$TMUX` after connecting; when the answer does not name our socket,
//       EVERY tmux command is refused for that run. `read_session` still works.
//
//   R1  SOCKET SELECTION. A tmux invocation that names a socket other than the agent's
//       own (`-L other`, `-S /path`) is refused. This is the whole rule, because naming
//       another socket is the only way a tmux command line can leave the agent's server.
//   R2  `kill-server`, and every prefix of it tmux would resolve. It ends the agent's own
//       shell mid-turn, and on a host that never got a private socket it ends everything.
//   R3  `pkill`/`killall` aimed at tmux. Not a tmux invocation at all — it kills EVERY
//       tmux server on the machine, which no socket boundary prevents.
//   R4  ANY command that edits the `TMUX` environment variable away (`TMUX= tmux …`,
//       `env -u TMUX tmux …`, and a bare `export TMUX=…` with no tmux command in the same
//       send — the guard judges one send at a time, so the assignment is its only moment
//       to act). Verified on tmux 3.6a against two private
//       sockets: with neither `-L` nor `-S`, tmux takes its socket path from `$TMUX`, so
//       overriding that variable selects a different server — including the default one.
//       This is the one hole the private socket does NOT close, and R4 catches only the
//       recognizable spellings of it. See daemon/README.md for the honest residual list.
//   R5  HALF A COMMAND IS NOT A COMMAND. The PTY concatenates sends, so a line ending in
//       a continuation or an open quote is refused when it mentions tmux — otherwise
//       `tmux -L \` and `other kill-server` are two individually-harmless sends the shell
//       joins at its continuation prompt, and R1 never sees a whole command.
//
// DELETED with the classification machinery: the 90-entry tmux command table, prefix
// resolution, target/`-t` extraction, session-reference parsing, the allow-list and the
// registry snapshot, `kill-session -a`/`send-keys -c` target inversion, the ssh-locality
// collectors (hostname + interface addresses), and the `fin-` namespace. None of them are
// load-bearing once every session on the agent's server is the agent's own.
//
// WHAT SURVIVES FROM THE OLD FILE, and why: the lexer. Finding a tmux invocation at all
// still has to see through shell quoting and escaping (`t\mux`, `tm"u"x`, `$'tmux'`,
// `TMUX` on a case-insensitive volume), through chaining (`;`, `|`, `&&`, `$( )`), and
// through wrappers that run their quoted arguments (`sh -c`, `eval`, `python3 -c`). Those
// were all verified to run tmux, and none of them contain the substring the cheap
// prefilter looks for. The lexer is kept, its tests are kept, and the fail-closed default
// is kept: when the guard cannot tell what a line will run, it refuses.

/// The guard's answer for one candidate `send_input` string.
public enum TmuxGuardVerdict: Equatable, Sendable {
    case allow
    /// An honest tool result the model can read and recover from — never a crash.
    case refuse(String)

    public var isRefusal: Bool {
        if case .refuse = self { return true }
        return false
    }

    public var refusalMessage: String? {
        if case .refuse(let message) = self { return message }
        return nil
    }
}

/// Which tmux *server* a command would reach. `-L name` / `-S path` pick one explicitly;
/// absent both, tmux uses `$TMUX` — i.e. the agent's own, which is the entire point.
public enum TmuxSocket: Equatable, Sendable {
    case standard
    case name(String)
    case path(String)

    /// Public so the daemon (a separate module) can name the socket in its own log lines;
    /// the refusal text uses the same words the operator sees.
    public var described: String {
        switch self {
        case .standard: return "the default socket"
        case .name(let value): return "-L \(value)"
        case .path(let value): return "-S \(value)"
        }
    }
}

/// The host-side policy object the engine holds: WHICH tmux server is the agent's own,
/// and whether the guard is enforced here at all.
///
/// `.unenforced` is a NAMED, deliberate value rather than a nil hook (contrast
/// `AgentTurnEngine.onNotify`, where nil legitimately means "no channel"): a guard must
/// never be disarmed by accident. It exists because the Fin app drives an arbitrary SSH
/// session where tmux is optional and the user's own session is often literally `main` —
/// enforcing there would refuse the user's own terminal.
public struct TmuxSendGuard: Sendable, Equatable {
    public var isEnforced: Bool
    /// The session the agent's own shell lives in, parsed out of `connectCommand`. Not a
    /// permission any more — nothing is target-checked — but the daemon logs it and the
    /// prompt names it, so the model knows which session is its own.
    public var ownSession: String?
    /// The socket the agent's own shell lives on, parsed out of `connectCommand`. THE
    /// load-bearing field: R1 refuses any explicit socket that is not this one.
    public var ownSocket: TmuxSocket
    /// Whether the shell was PROVEN to be inside `ownSocket`'s server (the daemon asks the
    /// live shell for `$TMUX` after connecting).
    ///
    /// R0, AND THE REASON IT EXISTS. Every other rule here assumes a bare `tmux …` reaches
    /// the agent's OWN server, which is true only because `$TMUX` points there — and that
    /// is a fact about a `connectCommand` typed into a PTY, which can fail quietly. If it
    /// did, the shell is a plain login shell with an empty `$TMUX`, a bare
    /// `tmux send-keys -t main …` names no socket for R1 to catch, and it lands on the
    /// human's server. So when the proof is missing, EVERY tmux invocation is refused: the
    /// agent still has `read_session` for looking, and a loudly crippled agent beats one
    /// quietly typing into someone else's terminal. Defaults to true so that a host which
    /// never probes (the app, every test that builds a guard by hand) behaves exactly as
    /// before; the daemon sets it from the probe's answer.
    public var shellIsOnOwnServer: Bool

    public init(
        isEnforced: Bool,
        ownSession: String?,
        ownSocket: TmuxSocket = .standard,
        shellIsOnOwnServer: Bool = true
    ) {
        self.isEnforced = isEnforced
        self.ownSession = ownSession
        self.ownSocket = ownSocket
        self.shellIsOnOwnServer = shellIsOnOwnServer
    }

    /// Does `raw` — the shell's own `$TMUX`, `<socket path>,<pid>,<session>` — say the
    /// shell is inside the server this guard defends? Pure, so the daemon's probe answer
    /// is testable without a tmux or a PTY.
    ///
    /// `.standard` cannot be proven this way and does not need to be: on the shared socket
    /// there is no confinement to lose, and requiring proof there would refuse every tmux
    /// command on a host that deliberately runs without a private socket.
    public static func shellReportIsOwnServer(_ raw: String?, socket: TmuxSocket) -> Bool {
        guard case .standard = socket else {
            guard let raw else { return false }
            let path = raw.split(separator: ",").first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !path.isEmpty else { return false }
            switch socket {
            case .name(let name):
                return TmuxCommandGuard.basename(path) == name
            case .path(let expected):
                return path == expected
            case .standard:
                return false
            }
        }
        return true
    }

    /// The explicit opt-out: a host with no tmux server of its own to stay inside.
    public static let unenforced = TmuxSendGuard(isEnforced: false, ownSession: nil)

    /// The daemon's derivation, from the same `connectCommand` the installer writes.
    /// Armed whenever that command attaches a tmux session (with or without `-L`) or the
    /// host has a routing registry — either fact means there is a server worth staying
    /// on. Absent both, the guard stays off and `send_input` behaves exactly as it did
    /// before this file existed.
    ///
    /// The registry no longer contributes any session NAMES (there is no allow-list to
    /// widen); its presence only arms the guard, so a host that registers sessions but
    /// has no tmux `connectCommand` still refuses explicit sockets rather than nothing.
    public static func forHost(connectCommand: String?, registryFileURL: URL?) -> TmuxSendGuard {
        let own = connectCommand.flatMap { TmuxCommandGuard.ownSessionName(inConnectCommand: $0) }
        let socket = connectCommand.map { TmuxCommandGuard.socket(inConnectCommand: $0) } ?? .standard
        let hasRegistry = registryFileURL.flatMap { RegistryDocument.loadIfPresent(at: $0) } != nil
        guard own != nil || hasRegistry else { return .unenforced }
        return TmuxSendGuard(isEnforced: true, ownSession: own, ownSocket: socket)
    }

    public func evaluate(_ input: String) -> TmuxGuardVerdict {
        guard isEnforced else { return .allow }
        // Ahead of everything else: `AgentTurnEngine` is main-actor, and every `git status`
        // the agent types goes through here. A command that cannot possibly be about tmux
        // must not pay for the lexer.
        guard TmuxCommandGuard.mightMentionTmux(input) else { return .allow }
        return TmuxCommandGuard.evaluate(
            input,
            ownSocket: ownSocket,
            ownSession: ownSession,
            shellIsOnOwnServer: shellIsOnOwnServer
        )
    }

    /// The prompt paragraph that tells the model where it lives and what it may do — a
    /// refusal the model understands beats a refusal it fights.
    public var promptSection: String? {
        guard isEnforced else { return nil }
        return TmuxCommandGuard.promptGuidance(ownSocket: ownSocket, ownSession: ownSession)
    }
}

/// The pure decision: given a command string and the agent's own socket, may it be typed?
/// Every decision is pure, so the whole rule set is unit-testable as strings.
public enum TmuxCommandGuard {

    // MARK: - Public API

    public static func evaluate(
        _ input: String,
        ownSocket: TmuxSocket = .standard,
        ownSession: String? = nil,
        shellIsOnOwnServer: Bool = true
    ) -> TmuxGuardVerdict {
        // Fast path AND blast-radius bound: a command that never mentions tmux (or a
        // process-killer aimed at it) is not this guard's business and must behave
        // byte-for-byte as it did before. The cheap test is on the RAW string, so it must
        // not be the only test — the shell assembles the word out of quoting and escaping
        // (`t\mux`, `tm"u"x`, and on this case-insensitive volume `TMUX`, all verified to
        // run tmux), and none of those contain the substring. Anything carrying a quote or
        // a backslash therefore falls through to the lexer, which normalizes exactly those
        // forms, and the real decision is made on lexed words.
        guard mightMentionTmux(input) else { return .allow }
        let context = Context(
            ownSocket: ownSocket,
            ownSession: ownSession,
            shellIsOnOwnServer: shellIsOnOwnServer
        )

        // THE GUARD JUDGES THE BYTES THAT ARE TYPED, not the raw tool argument.
        // `AgentTurnEngine` sends `AgentTurnLogic.typedBody(input)` and then a separate
        // `\r`, and its forced pre-classification path appends a `\n` to EVERY command it
        // extracts. Judging the untrimmed argument let that newline disarm R5:
        // `"tmux -L x \\\n"` does not *end* in a backslash, so it was allowed — while the
        // PTY really did sit at PS2 waiting for the next send to complete the command.
        let line = AgentTurnLogic.typedBody(input)
        let mentions = mentionsTmux(line)

        // R5. A fragment that could still BECOME `tmux` (`t\`, `tm\`) counts.
        if endsInLineContinuation(line) || hasUnterminatedQuote(line),
           mentions || trailingWordCouldBecomeTmux(line) {
            return .refuse(halfCommandRefusal(context: context))
        }

        // R4, AHEAD OF THE `mentions` GATE, and deliberately not requiring a tmux command
        // in the same send. `export TMUX=/private/tmp/tmux-501/default` contains no tmux
        // TOKEN at all (its basename is `default`), so the gate below would allow it — and
        // the very next send's bare `tmux send-keys -t main …` would then be judged, and
        // allowed, against a variable that no longer points at Fin's own server. The guard
        // sees one send at a time, so the assignment is the only moment it can act. There
        // is no legitimate reason for the agent to edit this variable.
        if segments(in: line).contains(where: { segmentEditsTmuxEnvironment($0) }) {
            return refusal(
                "that command unsets or overrides the TMUX environment variable. tmux reads its "
                    + "server socket out of $TMUX when no -L/-S is given, so editing it points every "
                    + "later tmux command at a DIFFERENT tmux server — including the one hosting the "
                    + "human's sessions. Fin's shell stays on its own server.",
                context: context
            )
        }

        guard mentions else { return .allow }

        // R0. The confinement this whole design rests on, checked before any rule that
        // assumes it: if the shell was never proven to be inside its own tmux server, a
        // bare `tmux …` names no socket for R1 to catch and would land on the default one.
        guard context.shellIsOnOwnServer else {
            return refusal(
                "Fin's shell was never confirmed to be inside its own tmux server, so a tmux "
                    + "command typed here could reach the machine's default tmux server — the one "
                    + "holding the human's sessions. Every tmux command is refused until that is "
                    + "fixed (the daemon's connectCommand did not take effect; it is logged).",
                context: context
            )
        }

        return evaluate(line: line, depth: 0, context: context)
    }

    /// The agent's own tmux session, parsed out of its `connectCommand`
    /// (`tmux -L fin new-session -A -s fin \; set status off` → `fin`).
    public static func ownSessionName(inConnectCommand command: String) -> String? {
        for invocation in invocations(in: command) {
            for sub in subcommands(of: invocation.arguments) {
                guard let verb = sub.first.map({ normalized($0.text) }), !verb.isEmpty else { continue }
                // tmux resolves unambiguous prefixes, and so does this: `new`, `new-s`,
                // `new-session` all name the session with `-s`; the attach family names it
                // with `-t`. Aliases (`new`, `attach`, `has`) are spelled out.
                let flag: Character
                if "new-session".hasPrefix(verb) || verb == "new" {
                    flag = "s"
                } else if "attach-session".hasPrefix(verb) || "switch-client".hasPrefix(verb)
                    || "has-session".hasPrefix(verb)
                    || ["attach", "switchc", "has"].contains(verb) {
                    flag = "t"
                } else {
                    continue
                }
                if let name = flagValue(flag, in: Array(sub.dropFirst())) { return name }
            }
        }
        return nil
    }

    /// Which tmux server the agent's own shell lives on, parsed out of `connectCommand`.
    /// This is what R1 compares against, so a `connectCommand` the parser cannot read
    /// yields `.standard` and the guard refuses every explicit socket — fail closed.
    public static func socket(inConnectCommand command: String) -> TmuxSocket {
        for invocation in invocations(in: command) {
            if let socket = invocation.socket { return socket }
        }
        return .standard
    }

    /// The prompt block the daemon appends when the guard is armed.
    public static func promptGuidance(ownSocket: TmuxSocket, ownSession: String?) -> String {
        let session = ownSession ?? "your own"
        let where_ = ownSocket == .standard
            ? "Your shell is on this machine's default tmux server."
            : "Your shell runs on your OWN tmux server (\(ownSocket.described)), which is a "
                + "different server process from the human's. Sessions you create there are "
                + "yours; the human's sessions do not exist on it at all."
        return """
            tmux (enforced in code, not just here). \(where_) You are in session \
            "\(session)", and every tmux command you type acts on YOUR server, so you may \
            create, drive, kill and rename sessions there freely — no allow-list, nothing to \
            register.

            To see work OUTSIDE your own terminal — the human's sessions, another agent's \
            session — use the read_session tool, not the shell. Call read_session with no \
            arguments to list this machine's sessions by name, then call it again with a name \
            to read that session's screen. That is the only path to them, and it is read-only.

            You may NOT point a tmux command at another server: `tmux -L <name>`, \
            `tmux -S <path>`, or anything that unsets or overrides the TMUX environment \
            variable is refused before a byte reaches the terminal, as are `kill-server` and \
            `pkill`/`killall tmux` (they would end your own shell, and every other tmux server \
            on this machine). The refusal is final — do not retry it, rephrase it, or wrap it \
            in a shell. If you need to see another server's work, read_session is the answer.
            """
    }

    // MARK: - Context

    struct Context {
        var ownSocket: TmuxSocket
        var ownSession: String?
        var shellIsOnOwnServer: Bool = true
    }

    /// Wrappers whose FIRST word is not the real command, so the tail has to be
    /// re-scanned for a tmux invocation (`ssh box tmux …`, `xargs tmux …`) and whose
    /// QUOTED arguments are program text they will run rather than data.
    ///
    /// The inline interpreters are here for the second reason only. `python3 -c "…
    /// os.system('tmux -L default kill-server')"` is not indirection and nothing is
    /// assembled at runtime — the word `tmux` and its socket flag sit in plain sight in a
    /// single send. Their payloads are unwrapped with the same lexer as a shell's. It does
    /// NOT catch an argv built structurally (`subprocess.run(["tmux", "-L", …])`), where no
    /// word is ever a command line; that shape is in the residual list in daemon/README.md.
    static let commandCarriers: Set<String> = [
        "ssh", "eval", "xargs", "watch", "timeout", "script", "flock", "su",
        "sh", "bash", "zsh", "dash", "fish", "ksh",
        "python", "python3", "perl", "ruby", "node", "osascript", "awk", "php",
    ]

    /// Stripped before the head is read (`sudo -n tmux …`, `env FOO=1 tmux …`).
    static let benignPrefixes: Set<String> = [
        "sudo", "doas", "command", "exec", "builtin", "env", "nohup", "setsid",
        "time", "nice", "stdbuf", "ionice", "caffeinate",
    ]

    /// Not tmux commands at all, but they reach every tmux server on the machine (R3).
    static let processKillers: Set<String> = ["pkill", "killall"]

    /// Shells whose bare form reads its program from stdin.
    static let stdinShells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh"]

    private static let maxNestingDepth = 3

    // MARK: - Evaluation

    static func evaluate(line: String, depth: Int, context: Context) -> TmuxGuardVerdict {
        let all = segments(in: line)
        // `evaluate(line:)` is only ever reached for a line that mentions tmux, so a shell
        // in that line with nothing to run is a shell that will run what the pipe hands it:
        // `echo "tmux -L default kill-server" | sh`. The guard can see the words but not
        // which of them the shell will execute, so it gets the fail-closed answer rather
        // than a parse.
        if let shell = all.first(where: { isShellReadingItsCommandsFromStdin($0) }) {
            return refusal(
                "`\(normalized(basename(shell[0].text)))` with no script and no `-c` runs whatever "
                    + "arrives on its stdin, and this line builds tmux text on the other side of the "
                    + "pipe — so which tmux server it would reach cannot be read from the line at "
                    + "all. Run the tmux command directly instead.",
                context: context
            )
        }
        for segment in all {
            let verdict = evaluate(segment: segment, depth: depth, context: context)
            if verdict.isRefusal { return verdict }
        }
        return .allow
    }

    /// `sh`, `bash …`, `zsh -x`, `sudo sh`: a shell whose arguments are all flags and none
    /// of them is `-c` has no program of its own — it reads one from stdin. The same
    /// benign prefixes `evaluate(segment:)` strips are stripped here, or `… | sudo sh`
    /// would walk straight past.
    static func isShellReadingItsCommandsFromStdin(_ segment: [Word]) -> Bool {
        var index = 0
        while index < segment.count {
            let token = segment[index].text
            if isEnvAssignment(token) || benignPrefixes.contains(normalized(basename(token))) {
                index += 1
                continue
            }
            if index > 0, token.hasPrefix("-") {
                index += 1
                continue
            }
            break
        }
        guard index < segment.count,
              stdinShells.contains(normalized(basename(segment[index].text))) else { return false }
        for word in segment[(index + 1)...] {
            guard word.text.hasPrefix("-"), word.text.count > 1 else { return false }
            if word.text.dropFirst().contains("c") { return false }
        }
        return true
    }

    private static func evaluate(segment words: [Word], depth: Int, context: Context) -> TmuxGuardVerdict {
        guard !words.isEmpty else { return .allow }

        // R4, FIRST, and on the WHOLE segment: `TMUX= tmux ls` and `env -u TMUX tmux ls`
        // both select a server other than the one `-L`/`-S` would name, without naming one.
        // Verified on tmux 3.6a with two private sockets: from inside a pane on socket A,
        // `TMUX=<socket B path>,0,0 tmux ls` listed socket B's sessions. tmux takes its
        // socket path from `$TMUX` when neither -S nor -L is given, so editing that
        // variable away is a socket selection wearing no flag.
        if segmentEditsTmuxEnvironment(words) {
            return refusal(
                "that command unsets or overrides the TMUX environment variable in front of a tmux "
                    + "command. tmux reads its server socket out of $TMUX when no -L/-S is given, so "
                    + "editing it away points tmux at a DIFFERENT tmux server — including the one "
                    + "hosting the human's sessions.",
                context: context
            )
        }

        // Strip `sudo`/`env FOO=1`/`exec`… to find the real head FIRST: every decision
        // below (does this head execute its quoted arguments?) is about the command that
        // will actually run, not the wrapper.
        var index = 0
        var strippedPrefix = false
        while index < words.count {
            let token = words[index].text
            if isEnvAssignment(token) {
                index += 1
                strippedPrefix = true
                continue
            }
            if strippedPrefix && token.hasPrefix("-") {
                index += 1
                continue
            }
            if benignPrefixes.contains(normalized(basename(token))) {
                index += 1
                strippedPrefix = true
                continue
            }
            break
        }
        guard index < words.count else { return .allow }

        let head = normalized(basename(words[index].text))
        let tail = Array(words[(index + 1)...])

        // R3.
        if processKillers.contains(head), tail.contains(where: { normalized($0.text).contains("tmux") }) {
            return refusal(
                "`\(head)` aimed at tmux kills EVERY tmux server on this machine — including the "
                    + "human's, which no socket boundary protects from a signal.",
                context: context
            )
        }

        // `xargs` builds tmux's argv out of stdin, which this guard cannot see:
        // `echo "-L default kill-server" | xargs tmux` selects another socket while the
        // guard sees an argument-less `tmux`.
        if head == "xargs", tail.contains(where: { isTmuxToken($0.text) }) {
            return refusal(
                "`xargs tmux` builds tmux's arguments out of stdin, which Fin's guard cannot see, "
                    + "so it cannot tell which tmux server the command would reach. Write the tmux "
                    + "command out in full on one line instead.",
                context: context
            )
        }

        // A quoted argument can be its own little command line — but ONLY when the head is
        // something that RUNS it: `sh -c '…'`, `eval "…"`, an inline interpreter's `-c`/`-e`
        // payload. Text that merely mentions tmux — `git commit -m "tmux guard: …"`,
        // `grep "tmux -L fin" daemon/`, `echo "tmux …" >> notes.md` — is data, and refusing
        // it cost real work in this very repo, whose current subject IS tmux commands.
        //
        // `depth > 0` is deliberate: below the top level we are ALREADY inside text some
        // runner will execute, so every quoted word in it is program text too. That is what
        // reaches the tmux inside `awk 'BEGIN{system("tmux -L x kill-server")}'`.
        if head == "tmux" || commandCarriers.contains(head) || depth > 0 {
            for word in words[index...] where word.wasQuoted && mentionsTmux(word.text, depth: depth + 1) {
                guard depth < maxNestingDepth else {
                    return refusal(
                        "that command nests tmux inside quoted shell text more deeply than Fin's "
                            + "guard will unwrap, so the server it would reach cannot be read.",
                        context: context
                    )
                }
                let verdict = evaluate(line: word.text, depth: depth + 1, context: context)
                if verdict.isRefusal { return verdict }
            }
        }

        if head == "tmux" {
            return evaluate(invocation: tail, context: context)
        }

        // `ssh localhost tmux …`, `sudo -u someone tmux …`, `timeout 60 tmux …`, and — as
        // the LAST RESORT — the bare word `tmux` under a head this parser does not model.
        // Every wrapper list is a list of things we happened to think of, and the ways past
        // the old one were not exotic: `find . -maxdepth 0 -exec tmux …`, `if tmux …; then`,
        // `for i in 1; do tmux …; done`. Only a BARE token counts, so prose keeps the word
        // inside a quoted word.
        let scanned = (commandCarriers.contains(head) || strippedPrefix)
            ? tail.firstIndex(where: { isTmuxToken($0.text) })
            : tail.firstIndex(where: { isTmuxToken($0.text) && !$0.wasQuoted })
        if let hit = scanned {
            return evaluate(invocation: Array(tail[(hit + 1)...]), context: context)
        }

        return .allow
    }

    /// One `tmux …` invocation: R1 on its global flags, then R2 on each `;`-separated
    /// command. Note what is NOT here any more — no verb table, no target extraction, no
    /// allow-list. Every session on the agent's own server is the agent's own.
    private static func evaluate(invocation args: [Word], context: Context) -> TmuxGuardVerdict {
        let parsed = parseGlobalFlags(args)

        // R1. THE RULE. A socket that is not ours puts the command on another server.
        if let socket = parsed.socket, socket != context.ownSocket {
            return refusal(
                "that tmux command names an explicit tmux server (\(socket.described)), which is "
                    + "not the one Fin's shell runs on (\(context.ownSocket.described)). Fin stays "
                    + "on its own tmux server; another server's sessions are read with the "
                    + "read_session tool, never driven from this shell.",
                context: context
            )
        }
        if parsed.danglingSocketFlag {
            return refusal(
                "that tmux command ends in a socket flag (`-L`/`-S`) with no value, so which tmux "
                    + "server it would reach depends on what is typed next, and Fin's guard judges "
                    + "one send at a time.",
                context: context
            )
        }

        // R2.
        for sub in subcommands(of: parsed.arguments) {
            guard let verb = sub.first.map({ normalized($0.text) }), !verb.isEmpty else { continue }
            if resolvesToKillServer(verb) {
                return refusal(
                    "`\(verb)` resolves to `kill-server`, which destroys a whole tmux server and "
                        + "every session on it — Fin's own shell included, and on a host without a "
                        + "private socket, the human's sessions too.",
                    context: context
                )
            }
        }
        return .allow
    }

    /// tmux resolves any UNAMBIGUOUS PREFIX of a command name, so `kill-serv` is
    /// `kill-server`. The conservative reading: any verb that is a prefix of `kill-server`
    /// is refused — including the short prefixes (`kill`, `kill-s`) that real tmux would
    /// reject as ambiguous anyway. `kill-session`, `kill-window` and `kill-pane` are NOT
    /// prefixes of `kill-server`, so they stay allowed: on Fin's own server they are
    /// Fin's own sessions.
    static func resolvesToKillServer(_ verb: String) -> Bool {
        !verb.isEmpty && "kill-server".hasPrefix(verb)
    }

    /// R4's detector: does this segment edit `TMUX` out of the environment?
    /// `TMUX=…` (an assignment prefix, an empty value included), `env -u TMUX`,
    /// `env --unset=TMUX`, POSIX `unset TMUX`, and fish's `set -e TMUX` / `set -x TMUX …`.
    ///
    /// The variable-name forms are anchored to a HEAD that edits the environment (`env`,
    /// `unset`, `set`) rather than looked for loose. Loose, `-e` followed by `tmux` made
    /// `grep -e tmux config.fish` a refusal — an ordinary read of a file about this very
    /// guard.
    static func segmentEditsTmuxEnvironment(_ words: [Word]) -> Bool {
        for (position, word) in words.enumerated() {
            let token = word.text
            if let equals = token.firstIndex(of: "="), isEnvAssignment(token),
               normalized(String(token[token.startIndex..<equals])) == "tmux" {
                return true
            }
            let head = normalized(basename(token))
            if head == "env" {
                // Only a name that follows an UNSET flag counts. `env tmux ls` is an
                // ordinary wrapper that edits nothing, and refusing it would be noise.
                var index = position + 1
                while index < words.count {
                    let argument = normalized(words[index].text)
                    if argument == "--unset=tmux" || argument == "-utmux" { return true }
                    if argument == "-u" || argument == "--unset" {
                        if index + 1 < words.count, normalized(words[index + 1].text) == "tmux" {
                            return true
                        }
                        index += 2
                        continue
                    }
                    // The first non-flag word is the command env will run: no more edits.
                    if !argument.hasPrefix("-") { break }
                    index += 1
                }
                continue
            }
            // `unset TMUX`, fish's `set -e TMUX`, fish's `set -x TMUX <path>`: the name is
            // an argument anywhere in the rest of the segment.
            guard head == "unset" || head == "set" else { continue }
            if words[(position + 1)...].contains(where: { normalized($0.text) == "tmux" }) {
                return true
            }
        }
        return false
    }

    // MARK: - Refusal text

    /// The refusal the MODEL reads. Its job is to end the attempt and redirect it:
    /// `send_input`'s own description tells the model not to ask before acting, so a vague
    /// refusal just gets retried. Hence: what was blocked, that it is final, and what to
    /// do instead — which since the private socket landed is always the same answer,
    /// `read_session`.
    static func refusal(_ headline: String, context: Context) -> TmuxGuardVerdict {
        var parts: [String] = []
        parts.append(
            "REFUSED by Fin's tmux guard: \(headline) Nothing was typed into the terminal. This is "
                + "a gate in code, not a preference — do not retry it, rephrase it, or wrap it in a "
                + "shell."
        )
        parts.append(
            "Your own tmux server (\(context.ownSocket.described)\(context.ownSession.map { ", session \"\($0)\"" } ?? "")) "
                + "is yours to drive without restriction: create, kill, rename and send keys to any "
                + "session on it."
        )
        parts.append(
            "To SEE a session on another server — the human's work, another agent's session — call "
                + "the read_session tool: with no arguments it lists this machine's sessions by "
                + "name, and with a name it returns that session's screen. It is read-only and it "
                + "is the supported path; there is no supported way to type into those sessions."
        )
        // The one legitimate shape this guard cannot tell from a command: a tmux command
        // line that is FILE CONTENT (a here-doc body, a doc, a script being written).
        // Nothing executes it, but the lexer sees the same words, and "do not rephrase"
        // would otherwise dead-end a documentation task in a repo whose current work is
        // this guard.
        parts.append(
            "If you were WRITING this line into a file rather than running it, do not use a "
                + "here-doc — Fin's guard cannot tell a here-doc body from a command. Write it with "
                + "a quoted argument instead, e.g. `printf 'tmux -L other ls\\n' >> notes.md`, which "
                + "is allowed because the tmux text is data there."
        )
        return .refuse(parts.joined(separator: " "))
    }

    /// The half-typed line gets its OWN refusal, because the standard one is wrong here:
    /// it says "do not retry or rephrase" when re-sending the command joined onto one line
    /// is exactly the right move.
    static func halfCommandRefusal(context: Context) -> String {
        "REFUSED by Fin's tmux guard: that line is only half a command — it ends in a shell "
            + "continuation (`\\`) or an unterminated quote, so what it finally runs depends on the "
            + "next thing typed, and Fin's guard judges one send at a time. Nothing was typed into "
            + "the terminal. This is the one refusal you SHOULD retry: send the whole command in a "
            + "single send_input, on one line, and it will be judged on what it actually does."
    }

    // MARK: - tmux argument parsing

    struct ParsedInvocation {
        var socket: TmuxSocket?
        var arguments: [Word]
        /// `tmux -L` with nothing after it: the value is whatever the next send supplies.
        var danglingSocketFlag: Bool = false
    }

    /// tmux's global flags: `tmux [-2CDlNuVv] [-c shell-command] [-f file] [-L socket-name]
    /// [-S socket-path] [-T features] [command …]`.
    ///
    /// GETOPT CLUSTERS. Reading `letters[0]` only meant a value-taking flag anywhere but
    /// first was skipped and ITS VALUE became the verb: `tmux -2L other kill-server` parsed
    /// as if no socket were named. Real tmux reads `-2`, then `-L other`, then the command.
    /// So: scan the whole cluster, and the first value-taking letter consumes the rest of
    /// the cluster or the next argument.
    ///
    /// The index arithmetic is the other half. A value flag in LAST position used to
    /// advance `index` twice — once inside the case, once at the loop bottom — so a bare
    /// `tmux -L` walked off the end and `args[index...]` trapped. A four-character
    /// `send_input` crashed the daemon, which is the one thing the guard's contract ("an
    /// honest tool result the model can read and recover from — never a crash") forbids.
    static func parseGlobalFlags(_ args: [Word]) -> ParsedInvocation {
        var socket: TmuxSocket?
        var dangling = false
        var index = 0
        while index < args.count {
            let token = args[index].text
            guard token.hasPrefix("-"), token.count > 1 else { break }
            let letters = Array(token.dropFirst())
            var position = 0
            while position < letters.count {
                let key = letters[position]
                // Only the value-taking flags matter, and only two of them select a
                // socket. `-f`/`-c`/`-T` are here purely so their VALUES are not mistaken
                // for the verb.
                guard key == "L" || key == "S" || key == "f" || key == "c" || key == "T" else {
                    position += 1
                    continue
                }
                var value = String(letters[(position + 1)...])
                if value.isEmpty {
                    if index + 1 < args.count {
                        index += 1
                        value = args[index].text
                    } else if key == "L" || key == "S" {
                        dangling = true
                    }
                }
                switch key {
                case "L": if !value.isEmpty { socket = .name(value) }
                case "S": if !value.isEmpty { socket = .path(value) }
                default: break
                }
                // The value ended the cluster, whether it came from these letters or the
                // next argument.
                position = letters.count
            }
            index += 1
        }
        return ParsedInvocation(
            socket: socket,
            arguments: index < args.count ? Array(args[index...]) : [],
            danglingSocketFlag: dangling
        )
    }

    /// tmux's own multi-command form: `tmux a \; b`.
    ///
    /// SHELL QUOTING CANNOT BE CONSULTED HERE. The shell removes quotes before tmux sees
    /// argv, so `\;`, `';'` and `";"` are byte-identical arguments and tmux separates on
    /// all three. tmux's actual rule (`cmd_parse_from_arguments`) is: an argument that ends
    /// in `;` ends the command, unless that `;` is itself backslash-escaped. Verified on
    /// tmux 3.6a, private socket: `tmux ls ';' rename-session -t other x` really did rename
    /// `other`.
    static func subcommands(of args: [Word]) -> [[Word]] {
        var result: [[Word]] = []
        var current: [Word] = []
        for word in args {
            guard word.text.hasSuffix(";"), !word.text.hasSuffix("\\;") else {
                current.append(word)
                continue
            }
            let stem = String(word.text.dropLast())
            if !stem.isEmpty { current.append(Word(text: stem, wasQuoted: word.wasQuoted)) }
            result.append(current)
            current = []
        }
        result.append(current)
        return result.filter { !$0.isEmpty }
    }

    /// The first value given to `-<flag>`, in the separated (`-s fin`), attached (`-sfin`)
    /// and CLUSTERED (`-As fin`, `-dt fin`) forms — used only for reading the agent's own
    /// session name out of its `connectCommand`, never for a permission decision.
    static func flagValue(_ flag: Character, in args: [Word]) -> String? {
        var index = 0
        while index < args.count {
            let token = args[index].text
            if token.hasPrefix("-"), !token.hasPrefix("--"), token.count > 1 {
                let letters = Array(token.dropFirst())
                if let position = letters.firstIndex(of: flag) {
                    let attached = String(letters[(position + 1)...])
                    if !attached.isEmpty { return attached }
                    if index + 1 < args.count { return args[index + 1].text }
                    return nil
                }
            }
            index += 1
        }
        return nil
    }

    // MARK: - Finding tmux invocations (used by connectCommand parsing)

    struct Invocation {
        var socket: TmuxSocket?
        var arguments: [Word]
    }

    static func invocations(in line: String) -> [Invocation] {
        var result: [Invocation] = []
        for segment in segments(in: line) {
            // `isTmuxToken`, not a raw basename compare: the case-fold is what every other
            // site uses, and a `connectCommand` written `TMUX -L fin new-session …` (legal
            // on this case-insensitive volume) otherwise yielded ownSocket == .standard,
            // which would make the guard refuse the agent's own server.
            guard let hit = segment.firstIndex(where: { isTmuxToken($0.text) }) else { continue }
            let parsed = parseGlobalFlags(Array(segment[(hit + 1)...]))
            result.append(Invocation(socket: parsed.socket, arguments: parsed.arguments))
        }
        return result
    }

    // MARK: - Lexing

    struct Word: Equatable {
        var text: String
        var wasQuoted: Bool
    }

    enum Lexeme: Equatable {
        case word(Word)
        case separator
    }

    static func segments(in line: String) -> [[Word]] {
        var result: [[Word]] = []
        var current: [Word] = []
        for lexeme in lex(line) {
            switch lexeme {
            case .word(let word):
                current.append(word)
            case .separator:
                if !current.isEmpty { result.append(current) }
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// A deliberately small shell lexer. It does NOT try to be a shell — it only has to
    /// find command boundaries and word boundaries well enough that a tmux invocation
    /// cannot hide behind ordinary quoting, escaping, or chaining. Command substitution
    /// (`$(…)`, backticks) is treated as a boundary, so `$(tmux -L other ls)` is parsed as
    /// its own segment rather than swallowed into a word.
    static func lex(_ line: String) -> [Lexeme] {
        var result: [Lexeme] = []
        var current = ""
        var started = false
        var quoted = false

        func flush() {
            if started { result.append(.word(Word(text: current, wasQuoted: quoted))) }
            current = ""
            started = false
            quoted = false
        }
        func separate() {
            flush()
            if result.last != .separator { result.append(.separator) }
        }

        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\\":
                index += 1
                if index < characters.count {
                    // A BACKSLASH-NEWLINE IS DELETED, not escaped — that is what every
                    // shell does with a line continuation, and it is how `t\` + newline +
                    // `mux -L other ls` becomes one word `tmux` in one send. Appending the
                    // newline instead produced the token `t\nmux`, which is not tmux to this
                    // parser and is tmux to the shell. (CRLF is a single Character in Swift,
                    // so it needs its own comparison.)
                    let escaped = characters[index]
                    if escaped == "\n" || escaped == "\r" || escaped == "\r\n" {
                        index += 1
                        continue
                    }
                    current.append(escaped)
                    started = true
                    index += 1
                }
                continue

            case "$":
                // ANSI-C and locale quoting: `$'tmux'` and `$"tmux"` run tmux in bash and
                // zsh (verified), and the `$` is not part of the word — without this the
                // token lexed as `$tmux` and the whole command was allowed unparsed. It is
                // the fourth spelling in the family with `TMUX`, `t\mux` and `tm"u"x`.
                // `$(`/`${` are already word boundaries below, so only the quote forms need
                // handling here.
                if index + 1 < characters.count,
                   characters[index + 1] == "'" || characters[index + 1] == "\"" {
                    index += 1
                    continue
                }
                current.append(character)
                started = true
                index += 1
                continue

            case "'":
                started = true
                quoted = true
                index += 1
                while index < characters.count, characters[index] != "'" {
                    current.append(characters[index])
                    index += 1
                }
                if index < characters.count { index += 1 }
                continue

            case "\"":
                started = true
                quoted = true
                index += 1
                while index < characters.count, characters[index] != "\"" {
                    if characters[index] == "\\", index + 1 < characters.count {
                        index += 1
                        current.append(characters[index])
                        index += 1
                        continue
                    }
                    current.append(characters[index])
                    index += 1
                }
                if index < characters.count { index += 1 }
                continue

            case " ", "\t":
                flush()
                index += 1
                continue

            case "\n", "\r", ";", "|", "&", "(", ")", "`", "{", "}", "<", ">":
                separate()
                index += 1
                continue

            default:
                current.append(character)
                started = true
                index += 1
            }
        }
        flush()
        return result
    }

    // MARK: - Finding the word `tmux`

    /// Case-folded, because the volume this ships on is case-insensitive: `TMUX -V` and
    /// `TmUx -V` both print a tmux version in bash, zsh and fish on this Mac.
    static func normalized(_ token: String) -> String { token.lowercased() }

    static func isTmuxToken(_ token: String) -> Bool { normalized(basename(token)) == "tmux" }

    /// The cheap prefilter. It must be a SUPERSET of what the lexer can find, so it cannot
    /// just look for the substring: a quote or a backslash anywhere means the shell may
    /// assemble the word out of pieces (`t\mux`, `tm"u"x`), and those forms run.
    static func mightMentionTmux(_ input: String) -> Bool {
        let lowered = normalized(input)
        if lowered.contains("tmux") || lowered.contains("pkill") || lowered.contains("killall") {
            return true
        }
        return input.contains("\\") || input.contains("'") || input.contains("\"")
    }

    /// The real test, on LEXED words: quoting and escaping are already undone here, so
    /// `t\mux`, `tm"u"x`, `TMUX` and `/opt/homebrew/bin/tmux` all answer true.
    static func mentionsTmux(_ line: String, depth: Int = 0) -> Bool {
        for segment in segments(in: line) {
            for word in segment {
                if isTmuxToken(word.text) { return true }
                if processKillers.contains(normalized(basename(word.text))) { return true }
                if word.wasQuoted, depth < maxNestingDepth, mentionsTmux(word.text, depth: depth + 1) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Half-typed lines (R5)

    /// An odd number of trailing backslashes is a shell line continuation: the next
    /// `send_input` is appended to this one at the PS2 prompt (verified:
    /// `printf 'tmux \\\n-V\n'` prints a tmux version in bash, zsh and fish).
    static func endsInLineContinuation(_ input: String) -> Bool {
        var backslashes = 0
        for character in input.reversed() {
            if character == "\\" { backslashes += 1 } else { break }
        }
        return backslashes % 2 == 1
    }

    /// A line that ends inside a quote is also waiting for the next send.
    static func hasUnterminatedQuote(_ input: String) -> Bool {
        let characters = Array(input)
        var index = 0
        while index < characters.count {
            switch characters[index] {
            case "\\":
                index += 2
            case "'":
                index += 1
                while index < characters.count, characters[index] != "'" { index += 1 }
                if index >= characters.count { return true }
                index += 1
            case "\"":
                index += 1
                while index < characters.count, characters[index] != "\"" {
                    if characters[index] == "\\" { index += 1 }
                    index += 1
                }
                if index >= characters.count { return true }
                index += 1
            default:
                index += 1
            }
        }
        return false
    }

    /// `t\` + `mux -L other kill-server`: neither half contains the word, but the shell
    /// joins them. A trailing fragment alone in command position that is a prefix of
    /// `tmux` is treated as the first half of one.
    static func trailingWordCouldBecomeTmux(_ input: String) -> Bool {
        guard let segment = segments(in: input).last, segment.count == 1, let word = segment.first else {
            return false
        }
        let fragment = normalized(word.text)
        return !fragment.isEmpty && "tmux".hasPrefix(fragment)
    }

    // MARK: - Small helpers

    static func basename(_ token: String) -> String {
        guard let slash = token.lastIndex(of: "/") else { return token }
        return String(token[token.index(after: slash)...])
    }

    static func isEnvAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { return false }
        let name = token[token.startIndex..<equals]
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
