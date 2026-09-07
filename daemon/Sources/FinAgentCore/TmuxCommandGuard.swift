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
// its OWN tmux socket (`exec tmux -L fin new-session -A -s fin`, written by
// scripts/mac-fin-agentd/provision-config.sh). `tmux -L` names a socket file, so the
// agent's tmux server is a different process from the one hosting the human's `main`;
// `exec` means leaving that tmux ends the SSH session rather than dropping the agent into
// the unconfined login shell underneath it.
// No string the model types inside that shell reaches `main` — not because we classified
// it, but because the server it would have to talk to is not the one its `$TMUX` points
// at. Correctness by topology, not by parsing. The read half that this costs is restored
// structurally too, by the `read_session` tool (`TmuxSessionRead`), which takes a session
// NAME and runs a fixed argv on a separate SSH exec channel.
//
// So this file's job collapsed to a SMALL, PROVABLE rule set. It is a second layer behind
// a real boundary, not the boundary itself:
//
//   R1  EVERY TMUX COMMAND NAMES ITS SERVER, AND IT IS OURS. On a host with a private
//       socket, a tmux invocation is allowed only when it says WHICH server it means and
//       that server is the agent's own (`tmux -L fin …`, or `-S <our path>`). Another
//       server is refused, and so is naming NO server at all.
//
//       THE SECOND HALF IS THE ONE THAT MATTERS, and it is why the previous round's
//       machinery is gone. A socket-less `tmux …` picks its server out of `$TMUX` — a fact
//       about the ENVIRONMENT the command happens to run in, which a byte-level guard can
//       only guess at. Guessing it took a live probe of the shell before every send (R0), a
//       named list of wrappers that start a fresh environment (R1b: `ssh`, `sudo`, `env -i`,
//       `launchctl`…), and an honest admission that both were incomplete — the probe is
//       answered by the very terminal the model types into, and the wrapper list is a list
//       of things we thought of. Demanding the flag deletes the question instead of
//       answering it: `tmux -L fin ls` reaches Fin's own server from a login shell, from
//       inside `ssh`, under `sudo`, with `env -i`, from a cron job — because the LABEL, not
//       the environment, chose the socket. tmux's own precedence is mirrored here: `-S`
//       WINS over `-L` no matter which came last (man tmux: "If -S is specified … any -L
//       flag is ignored" — verified on tmux 3.6a, where `tmux -S /nonexistent -L fintest ls`
//       tried the -S path).
//
//       The cost is that the model must type six extra characters, and the refusal spells
//       them out. That is the whole price for a rule whose correctness does not depend on
//       anything outside the string being judged.
//   R2  `kill-server`, and every prefix of it tmux would resolve. It ends the agent's own
//       shell mid-turn, and on a host that never got a private socket it ends everything.
//   R3  A SIGNAL aimed at tmux — `pkill`/`killall tmux`, and `kill` on a line that names
//       tmux (`kill $(pgrep tmux)`). Not a tmux invocation at all; a signal reaches EVERY
//       tmux server on the machine, which no socket boundary prevents. Judged on the whole
//       line because the pid comes from somewhere else on it.
//   R4  ANY command that edits a SOCKET-SELECTING environment variable away (`TMUX= tmux …`,
//       `env -u TMUX tmux …`, `export TMUX_TMPDIR=…`, and a bare `export TMUX=…` with no
//       tmux command in the same send — the guard judges one send at a time, so the
//       assignment is its only moment to act). `TMUX` matters much less now that R1 refuses
//       socket-less commands, but `TMUX_TMPDIR` matters MORE: it is the DIRECTORY a
//       `-L <label>` resolves in, so it re-points even the agent's OWN label at any socket
//       file the model picks (verified on tmux 3.6a: `TMUX_TMPDIR=<dir> tmux -L fintest2 …`
//       connected to `<dir>/tmux-501/fintest2`). That is the one hole the private socket
//       does not close, and R4 catches only the recognizable spellings of it. See
//       daemon/README.md for the honest residual list.
//   R5  HALF A COMMAND IS NOT A COMMAND. The PTY concatenates sends, so a line ending in
//       a continuation or an open quote is refused when it mentions tmux — otherwise
//       `tmux -L \` and `fin ls` are two individually-harmless sends the shell joins at its
//       continuation prompt, and R1 never sees a whole command.
//   R6  A PROGRAM NAME THE GUARD CANNOT READ. `$(which tmux) -L default send-keys -t main …`
//       puts the word `tmux` and the socket flag in two different lexer segments, so R1 saw
//       an argument list with no program and a program with no arguments. Any line that
//       mentions tmux and starts a command with a substitution (`$(…)`/backticks in command
//       position) is refused whole: which program runs there cannot be read from the line.
//   R7  A TMUX LINE HANDED TO A SCHEDULER (`crontab -`, `at`, `launchctl`) is refused,
//       because what it will run later is text this send only PIPES — `echo '… tmux …' |
//       crontab -` never puts the tmux words in a command position the guard can judge.
//       Line-level, for the same reason R3 is.
//
// DELETED THIS ROUND, with the questions they were answering: R0's live confinement probe
// (`$TMUX` scraped from the PTY before every tmux-bearing send — a proof produced by the
// party being checked, and an `echo` typed into whatever program was in the foreground),
// R1b's environment-crossing wrapper list, and `env -i` detection. R1's second half makes
// all three unnecessary: no rule below asks any more where a socket-less tmux would land,
// because a socket-less tmux does not run.
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
    /// load-bearing field: R1 refuses every tmux invocation that does not name exactly
    /// this socket.
    public var ownSocket: TmuxSocket

    public init(
        isEnforced: Bool,
        ownSession: String?,
        ownSocket: TmuxSocket = .standard
    ) {
        self.isEnforced = isEnforced
        self.ownSession = ownSession
        self.ownSocket = ownSocket
    }

    /// Does `raw` — the shell's own `$TMUX`, `<socket path>,<pid>,<session>` — say the
    /// shell is inside the server this guard defends?
    ///
    /// NOT A GATE, AND DELIBERATELY NOT ONE ANY MORE. The daemon calls this once at launch
    /// so an operator learns from the log that the `connectCommand` did or did not take
    /// effect. It is not consulted per send, and no refusal depends on it, because the
    /// answer comes back through the same PTY the model types into: a filter left running
    /// in the pane can print whatever this function wants to read. R1's demand that every
    /// tmux command name its own socket is what replaced it — a rule about the string being
    /// judged, not about a terminal that can answer for itself.
    ///
    /// `.standard` cannot be proven this way and does not need to be: on the shared socket
    /// there is no confinement to lose.
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
    /// Armed whenever that command attaches a tmux session (with or without `-L`), names a
    /// SOCKET, or the host has a routing registry — any of the three means there is a
    /// server worth staying on. Absent all three, the guard stays off and `send_input`
    /// behaves exactly as it did before this file existed.
    ///
    /// THE SOCKET ARMS IT TOO, and that clause is not decoration: a hand-edited
    /// `connectCommand` such as `tmux -L fin attach-session` (or `tmux -L fin new-session
    /// -A`, no `-s`) yields no session name at all, and on a host whose routing registry was
    /// never created that used to leave the guard `.unenforced` — a private socket with
    /// nothing defending the way off it. A parsed `-L`/`-S` is the clearest possible
    /// statement that this host has its own tmux server.
    ///
    /// The registry no longer contributes any session NAMES (there is no allow-list to
    /// widen); its presence only arms the guard, so a host that registers sessions but
    /// has no tmux `connectCommand` still refuses explicit sockets rather than nothing.
    public static func forHost(connectCommand: String?, registryFileURL: URL?) -> TmuxSendGuard {
        let own = connectCommand.flatMap { TmuxCommandGuard.ownSessionName(inConnectCommand: $0) }
        let socket = connectCommand.map { TmuxCommandGuard.socket(inConnectCommand: $0) } ?? .standard
        let hasRegistry = registryFileURL.flatMap { RegistryDocument.loadIfPresent(at: $0) } != nil
        guard own != nil || hasRegistry || socket != .standard else { return .unenforced }
        return TmuxSendGuard(isEnforced: true, ownSession: own, ownSocket: socket)
    }

    public func evaluate(_ input: String) -> TmuxGuardVerdict {
        guard isEnforced else { return .allow }
        // Ahead of everything else: `AgentTurnEngine` is main-actor, and every `git status`
        // the agent types goes through here. A command that cannot possibly be about tmux
        // must not pay for the lexer.
        guard TmuxCommandGuard.mightMentionTmux(input) else { return .allow }
        return TmuxCommandGuard.evaluate(input, ownSocket: ownSocket, ownSession: ownSession)
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
        ownSession: String? = nil
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
        let context = Context(ownSocket: ownSocket, ownSession: ownSession)

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
                "that command unsets or overrides a variable tmux picks its SERVER from (TMUX, or "
                    + "TMUX_TMPDIR — the directory a -L label is resolved in). tmux reads its socket "
                    + "out of $TMUX when no -L/-S is given, and resolves `-L <label>` under "
                    + "$TMUX_TMPDIR, so editing either points later tmux commands at a DIFFERENT tmux "
                    + "server — including the one hosting the human's sessions. Fin's shell stays on "
                    + "its own server.",
                context: context
            )
        }

        guard mentions else { return .allow }
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
    ///
    /// TWO POSTURES, AND THEY GET DIFFERENT PARAGRAPHS. On a private socket the model
    /// really does own every session it can reach, and the rule it must learn is the flag.
    /// On the SHARED default socket there is no boundary to describe: the human's sessions
    /// are on the same server, this file cannot tell them from the agent's own, and saying
    /// "every tmux command acts on YOUR server … create, drive, kill and rename freely"
    /// there was an invitation contradicting the routing section's OFF-LIMITS rule. The
    /// shared posture is told the truth instead: the restraint is the instruction, not the
    /// code.
    public static func promptGuidance(ownSocket: TmuxSocket, ownSession: String?) -> String {
        let session = ownSession ?? "your own"
        guard ownSocket != .standard else {
            return """
                tmux. Your shell is on this machine's DEFAULT tmux server — the same server \
                the human's own sessions live on. You are in session "\(session)". Sessions \
                you did not create are NOT yours: never send keys to them, never kill, rename \
                or reconfigure them, and never attach to one. Read them with the read_session \
                tool (no arguments lists this machine's sessions, a name reads that session's \
                screen) rather than with the shell.

                Be honest with yourself about this one: unlike the sites that run on their own \
                tmux socket, nothing here separates your sessions from the human's at the \
                process level, so this paragraph — not a gate in code — is what keeps you out \
                of them. `kill-server` and any signal aimed at tmux (`pkill tmux`, \
                `kill $(pgrep tmux)`) ARE refused in code, because they would take down every \
                session on this machine including your own shell.
                """
        }
        return """
            tmux (enforced in code, not just here). Your shell runs on your OWN tmux server \
            (\(ownSocket.described)), a different server process from the human's: the human's \
            sessions do not exist on it at all. You are in session "\(session)", and every \
            session on your server is yours to create, drive, kill and rename freely — no \
            allow-list, nothing to register.

            WRITE THE SOCKET FLAG EVERY TIME: `tmux \(ownSocket.described) <command>`, e.g. \
            `tmux \(ownSocket.described) new-session -d -s build` or \
            `tmux \(ownSocket.described) send-keys -t build 'swift build' Enter`. A tmux \
            command with no `-L`/`-S` picks its server out of the $TMUX variable of whatever \
            shell happens to run it, which is not something Fin can check from the command \
            text — so a socket-less `tmux …` is refused, whatever it would have done. Adding \
            the flag is the whole fix, and it works everywhere: in this shell, under `ssh`, \
            under `sudo`, inside a script.

            To see work OUTSIDE your own server — the human's sessions, another agent's \
            session — use the read_session tool, not the shell. Call read_session with no \
            arguments to list this machine's sessions by name, then call it again with a name \
            to read that session's screen. That is the only path to them, and it is read-only.

            Also refused before a byte reaches the terminal: any OTHER server \
            (`tmux -L <other>`, `tmux -S <path>`), anything that edits the TMUX or \
            TMUX_TMPDIR environment variables (TMUX_TMPDIR re-points even your own label), \
            `kill-server`, and any signal aimed at tmux (`pkill tmux`, `kill $(pgrep tmux)` — \
            they would end your own shell, and every other tmux server on this machine). \
            Those refusals are final — do not retry, rephrase, or wrap them in a shell. If you \
            need to see another server's work, read_session is the answer.
            """
    }

    // MARK: - Context

    /// What the rules are judged against. Note what is NOT in here any more: any notion of
    /// which environment the command will run in. R1 asks only what the command SAYS.
    struct Context {
        var ownSocket: TmuxSocket
        var ownSession: String?

        /// The one-word fix every R1 refusal ends with, spelled the way tmux takes it.
        var ownSocketFlag: String { ownSocket.described }
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

    /// R7. Heads that take a command now and RUN it later, out of this send's sight. The
    /// tmux words they carry are almost always data at the moment they are typed —
    /// `echo '* * * * * tmux -L default kill-server' | crontab -` puts them in a quoted
    /// argument of `echo`, on a different segment from the scheduler — so no amount of
    /// per-segment parsing reaches them, and the schedule fires a minute later in a shell
    /// nobody is judging. Refusing the whole line is the only honest answer, and it is
    /// judged line-level for exactly the reason R3 is.
    ///
    /// Deliberately SHORT. This is not the old wrapper list reborn: `ssh`, `sudo` and
    /// `env -i` are gone from the guard entirely, because R1 no longer cares which
    /// environment a tmux command runs in. These five are here because they defer, not
    /// because they cross.
    static let schedulers: Set<String> = ["crontab", "at", "batch", "launchctl", "systemd-run"]

    /// Not tmux commands at all, but they reach every tmux server on the machine (R3).
    /// `processKillers` is also part of the cheap prefilter, so it stays limited to the
    /// words that are ONLY ever signals; `signalSenders` is the rule's own set and
    /// includes plain `kill`, whose pid usually comes from elsewhere on the line
    /// (`kill $(pgrep tmux)`).
    static let processKillers: Set<String> = ["pkill", "killall"]
    static let signalSenders: Set<String> = ["kill", "pkill", "killall"]

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
        // R3, AND IT IS A LINE-LEVEL RULE ON PURPOSE. A signal is not a tmux command and no
        // socket boundary stops one — `pkill tmux` ends every tmux server on this machine,
        // the human's included. The pid does not have to be on the same segment as the
        // signal: `kill $(pgrep tmux)` lexes as `kill $` and `pgrep tmux`, and judging
        // segment by segment saw a `kill` with no tmux in it and a `pgrep` that harms
        // nothing. So: any signal-sending head anywhere on a line that names tmux is
        // refused. `pkill node` and `killall Dock` are untouched, because the tmux WORD (not
        // merely a process-killer word) has to be on the line.
        let namesTmux = mentionsTmuxWord(line, depth: depth)
        if namesTmux,
           let killer = all.compactMap({ commandHead($0) }).first(where: { signalSenders.contains($0) }) {
            return refusal(
                "`\(killer)` on a line that names tmux sends a SIGNAL, which reaches every tmux "
                    + "server on this machine — including the human's, which no socket boundary "
                    + "protects from a signal. Fin's own sessions are ended with "
                    + "`tmux \(context.ownSocketFlag) kill-session -t <name>`, which stays on "
                    + "Fin's server.",
                context: context
            )
        }

        // R6, LINE-LEVEL, AND FOR THE SAME REASON. `$(which tmux) -L default send-keys -t
        // main …` hands the guard two halves it cannot join: the lexer makes `(` and `)`
        // hard boundaries, so the word `tmux` lands in one segment and `-L default …` in
        // the next, as an argument list whose program name was never a word at all. R1 read
        // an empty invocation and allowed it. Verified on a private socket that
        // `$(which tmux) -L fintest … ls` and its backtick spelling really do select the
        // named socket, so this is a live route with `default` substituted. There is no
        // parse of this: a substitution's output is known only at runtime.
        if namesTmux, startsACommandWithSubstitution(line) {
            return refusal(
                "that line starts a command with a substitution (`$(…)` or backticks) on a line "
                    + "that names tmux, so which PROGRAM runs there is decided at runtime and "
                    + "cannot be read from the command text — `$(which tmux) -L default …` is a "
                    + "tmux command wearing no tmux word. Write the program out: "
                    + "`tmux \(context.ownSocketFlag) …`.",
                context: context
            )
        }

        // R7. A scheduler on a tmux line: what it runs happens later, in a shell this send
        // is not.
        if namesTmux, let scheduler = all.compactMap({ commandHead($0) }).first(where: {
            schedulers.contains($0)
        }) {
            return refusal(
                "`\(scheduler)` schedules a command to run LATER, in a shell Fin's guard will "
                    + "never see, and this line carries tmux text into it (a piped here-string, a "
                    + "quoted crontab line, a plist argument — none of them are in a command "
                    + "position this guard can judge). Run the tmux command directly instead: "
                    + "`tmux \(context.ownSocketFlag) …`.",
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
                "that command unsets or overrides a variable tmux picks its SERVER from (TMUX, or "
                    + "TMUX_TMPDIR — the directory a -L label is resolved in) in front of a tmux "
                    + "command. tmux reads its socket out of $TMUX when no -L/-S is given, and "
                    + "resolves `-L <label>` under $TMUX_TMPDIR, so editing either away points tmux "
                    + "at a DIFFERENT tmux server — including the one hosting the human's sessions.",
                context: context
            )
        }

        // Strip `sudo`/`env FOO=1`/`exec`… to find the real head FIRST: every decision
        // below (does this head execute its quoted arguments?) is about the command that
        // will actually run, not the wrapper.
        let parsedHead = headIndex(of: words)
        let index = parsedHead.index
        let strippedPrefix = parsedHead.strippedPrefix
        guard index < words.count else { return .allow }

        let head = normalized(basename(words[index].text))
        let tail = Array(words[(index + 1)...])

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

        // A word the shell BUILT — by quoting or by escaping — can be its own little
        // command line, but only when the head is something that RUNS it: `sh -c '…'`,
        // `eval "…"`, an inline interpreter's `-c`/`-e` payload. Text that merely mentions
        // tmux — `git commit -m "tmux guard: …"`, `grep "tmux -L fin" daemon/`,
        // `echo "tmux …" >> notes.md` — is data, and refusing it cost real work in this very
        // repo, whose current subject IS tmux commands.
        //
        // QUOTING IS NOT THE ONLY WAY TO BUILD ONE, and reading only `wasQuoted` was a hole
        // wide enough to drive the whole guard through: `sh -c tmux\ -L\ default\ send-keys\
        // -t\ main\ hostname\ Enter` lexes to exactly three words, none of them quoted, the
        // third being a complete command line the shell hands to `sh` to re-parse (verified
        // in bash AND fish: `bash -c 'sh -c echo\ hi\ there'` prints the multi-word result).
        // `mentionsTmux` therefore answered false and `evaluate` short-circuited to .allow
        // before a single rule ran. So the lexer records HOW a word was built, and both
        // spellings are unwrapped.
        //
        // `depth > 0` is deliberate: below the top level we are ALREADY inside text some
        // runner will execute, so every built word in it is program text too. That is what
        // reaches the tmux inside `awk 'BEGIN{system("tmux -L x kill-server")}'`.
        if head == "tmux" || commandCarriers.contains(head) || depth > 0 {
            for word in words[index...]
            where word.wasAssembled && mentionsTmux(word.text, depth: depth + 1) {
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
            return evaluate(invocation: tail, context: context, inCommandPosition: true)
        }

        // `ssh localhost tmux …`, `sudo -u someone tmux …`, `timeout 60 tmux …`, and — as
        // the LAST RESORT — the bare word `tmux` under a head this parser does not model.
        // Every wrapper list is a list of things we happened to think of, and the ways past
        // the old one were not exotic: `find . -maxdepth 0 -exec tmux …`, `if tmux …; then`,
        // `for i in 1; do tmux …; done`. Only a BARE token counts, so prose keeps the word
        // inside a quoted word.
        let runsItsArguments = commandCarriers.contains(head) || strippedPrefix
        let scanned = runsItsArguments
            ? tail.firstIndex(where: { isTmuxToken($0.text) })
            : tail.firstIndex(where: { isTmuxToken($0.text) && !$0.wasAssembled })
        if let hit = scanned {
            // IS THIS TMUX A COMMAND, OR A WORD ABOUT TMUX? Under a head we recognize as a
            // runner (`ssh box tmux …`, `timeout 60 tmux …`) or behind a stripped prefix
            // (`sudo -u levi tmux …`) the token is unambiguously a program, and R1 applies
            // in full. Under a head this parser does NOT model it is far more often prose —
            // `man tmux`, `which tmux`, `brew install tmux`, `grep -e tmux config.fish` —
            // and demanding a socket flag there would refuse an ordinary read of the very
            // file this guard is configured in. So an unmodelled head keeps the rules that
            // are unambiguous (another server, `kill-server`) and skips the one that is not.
            // The gap that leaves — `find . -exec tmux send-keys …`, socket-less, under a
            // head we don't know — is in daemon/README.md's residual list.
            return evaluate(
                invocation: Array(tail[(hit + 1)...]),
                context: context,
                inCommandPosition: runsItsArguments
            )
        }

        return .allow
    }

    /// Where the real command starts in a segment, with `sudo`/`env FOO=1`/`exec`… and
    /// their flags stripped off the front. Shared by `evaluate(segment:)` and the
    /// line-level rules, so both agree on what the head is.
    static func headIndex(of words: [Word]) -> (index: Int, strippedPrefix: Bool) {
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
        return (index, strippedPrefix)
    }

    /// The command a segment will actually run, prefixes stripped. Nil when the segment is
    /// nothing but prefixes.
    static func commandHead(_ words: [Word]) -> String? {
        let index = headIndex(of: words).index
        guard index < words.count else { return nil }
        return normalized(basename(words[index].text))
    }

    /// One `tmux …` invocation: R1 on its global flags, then R2 on each `;`-separated
    /// command. Note what is NOT here any more — no verb table, no target extraction, no
    /// allow-list. Every session on the agent's own server is the agent's own.
    private static func evaluate(
        invocation args: [Word],
        context: Context,
        inCommandPosition: Bool
    ) -> TmuxGuardVerdict {
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

        // R1, THE SECOND HALF — the one that replaced a live shell probe and a list of
        // wrappers. No socket flag means "whatever `$TMUX` says", and `$TMUX` belongs to
        // whatever shell ends up running the command: this one, the fresh login `ssh` opens,
        // the environment `sudo` resets, the empty one `env -i` leaves, the cron shell an
        // hour from now. With it unset, tmux falls back to the label `default` — the
        // human's server. The previous rounds tried to work out WHICH of those it would be,
        // from the command text plus a probe of the live shell; both were incomplete and
        // the probe was answerable by the model. So the question is deleted instead:
        // a tmux command on a private-socket host must say which server it means.
        //
        // Not on `.standard`. There the agent's own server IS the default one, so there is
        // no flag that would say anything, and demanding one would refuse every tmux
        // command on a host deliberately installed without a private socket.
        if parsed.socket == nil, inCommandPosition, context.ownSocket != .standard {
            return refusal(
                "that tmux command names no tmux server. A tmux command with no `-L`/`-S` takes "
                    + "its socket from the $TMUX variable of whichever shell runs it — this one, or "
                    + "a fresh one under ssh/sudo/cron where $TMUX is empty and tmux falls back to "
                    + "this machine's DEFAULT socket, the one holding the human's sessions. Fin "
                    + "cannot tell those apart from the command text, so it does not try: write "
                    + "your own server into the command and it is allowed — "
                    + "`tmux \(context.ownSocketFlag) \(describe(parsed.arguments))`.",
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

    /// THE VARIABLES THAT SELECT A TMUX SERVER, and there are two of them.
    ///
    /// `TMUX` is the socket path itself: with neither `-L` nor `-S`, tmux reads it from
    /// there (verified on tmux 3.6a between two private sockets), and unset it falls back
    /// to the label `default` — the human's server.
    ///
    /// `TMUX_TMPDIR` is the DIRECTORY a `-L <label>` is resolved in
    /// (`$TMUX_TMPDIR/tmux-<uid>/<label>`), so it re-points even the agent's OWN label at
    /// any socket file the model chooses — a symlink included. Verified here on a private
    /// label: `TMUX_TMPDIR=<dir> tmux -L fintest2 new-session -d` tried to connect to
    /// `<dir>/tmux-501/fintest2`. Without this clause `set -gx TMUX_TMPDIR …` was a command
    /// with no tmux TOKEN in it at all, and the `tmux -L fin …` that followed read as
    /// "my own socket".
    static func isSocketSelectingVariable(_ name: String) -> Bool {
        let lowered = normalized(name)
        return lowered == "tmux" || lowered == "tmux_tmpdir"
    }

    /// R4's detector: does this segment edit a socket-selecting variable out of the
    /// environment? `TMUX=…`/`TMUX_TMPDIR=…` (an assignment prefix, an empty value
    /// included), `env -u TMUX`, `env --unset=TMUX`, POSIX `unset TMUX`, and fish's
    /// `set -e TMUX` / `set -x TMUX …`.
    ///
    /// The variable-name forms are anchored to a HEAD that edits the environment (`env`,
    /// `unset`, `set`) rather than looked for loose. Loose, `-e` followed by `tmux` made
    /// `grep -e tmux config.fish` a refusal — an ordinary read of a file about this very
    /// guard.
    static func segmentEditsTmuxEnvironment(_ words: [Word]) -> Bool {
        for (position, word) in words.enumerated() {
            let token = word.text
            if let equals = token.firstIndex(of: "="), isEnvAssignment(token),
               isSocketSelectingVariable(String(token[token.startIndex..<equals])) {
                return true
            }
            let head = normalized(basename(token))
            if head == "env" {
                // Only a name that follows an UNSET flag counts. `env tmux ls` is an
                // ordinary wrapper that edits nothing, and refusing it would be noise.
                var index = position + 1
                while index < words.count {
                    let argument = normalized(words[index].text)
                    if argument.hasPrefix("--unset="),
                       isSocketSelectingVariable(String(argument.dropFirst("--unset=".count))) {
                        return true
                    }
                    if argument.hasPrefix("-u"), argument.count > 2,
                       isSocketSelectingVariable(String(argument.dropFirst(2))) {
                        return true
                    }
                    if argument == "-u" || argument == "--unset" {
                        if index + 1 < words.count, isSocketSelectingVariable(words[index + 1].text) {
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
            if words[(position + 1)...].contains(where: { isSocketSelectingVariable($0.text) }) {
                return true
            }
        }
        return false
    }

    /// R6's detector: does this line START a command with a command substitution?
    ///
    /// `$(which tmux) -L default send-keys -t main …` is the shape. The lexer makes `(`,
    /// `)` and backticks hard boundaries — deliberately, so `$(tmux -L other ls)` is judged
    /// as its own command — and that same boundary splits this line into a segment holding
    /// the word `tmux` and a segment holding `-L default send-keys …` with no program in
    /// it. Neither half is a tmux invocation the rest of this file can read, and the two
    /// were never joined.
    ///
    /// The distinguishing feature is COMMAND POSITION: a substitution that begins where a
    /// program name goes produces the program. `echo $(date)`, `X=$(which tmux)` and
    /// `kill $(pgrep tmux)` all have their substitution in ARGUMENT position, and none of
    /// them is refused by this (the last one is R3's business). So the scan tracks one bit
    /// — has anything but whitespace been seen since the last command boundary — and fires
    /// only on `$(` or a backtick reached while that bit is false.
    static func startsACommandWithSubstitution(_ line: String) -> Bool {
        let characters = Array(line)
        var index = 0
        var atCommandStart = true
        while index < characters.count {
            let character = characters[index]
            switch character {
            case " ", "\t":
                index += 1
            case "\n", "\r", ";", "|", "&", "(", ")", "{", "}", "<", ">":
                // A boundary: whatever follows is the start of a command again. `(` and `)`
                // are included because `( tmux … )` and the tail of a substitution both
                // begin a fresh command position; a redirection can precede the program
                // name too (`> out $(which tmux) …`).
                atCommandStart = true
                index += 1
            case "`":
                if atCommandStart { return true }
                index += 1
            case "$":
                if atCommandStart, index + 1 < characters.count, characters[index + 1] == "(" {
                    return true
                }
                atCommandStart = false
                index += 1
            default:
                atCommandStart = false
                index += 1
            }
        }
        return false
    }

    // MARK: - Refusal text

    /// The tmux command the model tried, echoed back into the fix so the refusal reads as
    /// a rewrite rather than a rule. Bounded and stripped of control characters — these
    /// words came from the model, and the result goes back into its context.
    static func describe(_ args: [Word]) -> String {
        // Control characters are replaced rather than passed through: this text goes into
        // the tool result the model reads AND into the audit trail, and a newline or an
        // escape sequence in a model-authored word could forge a line in either.
        let flattened = String(
            args.map(\.text).joined(separator: " ").unicodeScalars.map { scalar -> Character in
                guard !CharacterSet.controlCharacters.contains(scalar) else { return " " }
                return Character(scalar)
            }
        )
        guard !flattened.isEmpty else { return "<command>" }
        return flattened.count > 60 ? String(flattened.prefix(60)) + "…" : flattened
    }

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
    ///
    /// `-S` BEATS `-L`, WHICHEVER CAME LAST. man tmux: "If -S is specified, the default
    /// socket directory is not used and any -L flag is ignored." Verified on tmux 3.6a
    /// (no default-socket contact): `tmux -S /nonexistent-fin-review/sock -L fintest ls`
    /// answered `error connecting to /nonexistent-fin-review/sock`, i.e. the -S path won
    /// over the later -L. Overwriting one `socket` variable per flag read the LAST one
    /// instead, so `tmux -S <the human's socket> -L fin send-keys -t main …` looked like
    /// Fin's own server and was allowed. The two flags are now tracked separately and
    /// resolved tmux's way.
    static func parseGlobalFlags(_ args: [Word]) -> ParsedInvocation {
        var socketName: String?
        var socketPath: String?
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
                case "L": if !value.isEmpty { socketName = value }
                case "S": if !value.isEmpty { socketPath = value }
                default: break
                }
                // The value ended the cluster, whether it came from these letters or the
                // next argument.
                position = letters.count
            }
            index += 1
        }
        return ParsedInvocation(
            // tmux's precedence, not "whichever was typed last".
            socket: socketPath.map { TmuxSocket.path($0) } ?? socketName.map { TmuxSocket.name($0) },
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
            if !stem.isEmpty {
                current.append(
                    Word(text: stem, wasQuoted: word.wasQuoted, wasEscaped: word.wasEscaped)
                )
            }
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

    /// A lexed word, plus HOW the shell built it — which is the difference between data
    /// and a command line when the word is handed to something that re-parses it.
    ///
    /// `wasQuoted` and `wasEscaped` are tracked separately rather than as one flag because
    /// they are found in different places in the lexer, but every caller wants the union:
    /// `sh -c 'tmux …'` and `sh -c tmux\ …` are the same command, and the second one used
    /// to be invisible (three unquoted words, the third a whole command line) which
    /// short-circuited the entire guard to `.allow` before any rule ran.
    struct Word: Equatable {
        var text: String
        var wasQuoted: Bool
        var wasEscaped: Bool = false

        /// Did the shell ASSEMBLE this word out of quoting or escaping — i.e. is its text
        /// something a carrier could re-parse as a command line?
        var wasAssembled: Bool { wasQuoted || wasEscaped }
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
        var assembledByEscape = false

        func flush() {
            if started {
                result.append(
                    .word(Word(text: current, wasQuoted: quoted, wasEscaped: assembledByEscape))
                )
            }
            current = ""
            started = false
            quoted = false
            assembledByEscape = false
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
                    // THE WORD WAS ASSEMBLED BY THE SHELL, exactly as quoting assembles
                    // one. `sh -c tmux\ -L\ default\ send-keys\ -t\ main\ hostname\ Enter`
                    // is a single word here — three words on the line — and the payload
                    // recursion used to unwrap only quoted words, so nothing looked inside
                    // it and the line was allowed with `-L default` in plain sight.
                    assembledByEscape = true
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
                if word.wasAssembled, depth < maxNestingDepth,
                   mentionsTmux(word.text, depth: depth + 1) {
                    return true
                }
            }
        }
        return false
    }

    /// Strictly the WORD tmux — R3's half of `mentionsTmux`, without the process-killer
    /// clause. R3 asks "is there a signal on a line that names tmux", and `mentionsTmux`
    /// answers true for `pkill node` (because `pkill` is in it), which would have refused
    /// every unrelated `pkill`/`kill`.
    static func mentionsTmuxWord(_ line: String, depth: Int = 0) -> Bool {
        for segment in segments(in: line) {
            for word in segment {
                if isTmuxToken(word.text) { return true }
                if word.wasAssembled, depth < maxNestingDepth,
                   mentionsTmuxWord(word.text, depth: depth + 1) {
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
