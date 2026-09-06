// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// The production port of `evals/tmux-routing/run_evals.py`'s GuardedTmuxExecutor —
// "the ONLY thing allowed to send keys… the allow-list comes from the registry, never
// from what happens to exist on the server."
//
// The eval executor had it easy: it was handed a session NAME. Production is handed a
// COMMAND STRING the model wrote, so this file is mostly a small, deliberately
// pessimistic shell/tmux parser sitting in front of that string.
//
// BE HONEST ABOUT WHAT THIS IS. A byte-level guard over a natural-language channel is
// defense in depth, not a sandbox. It closes the direct path — the one a local model
// actually takes when it decides to be helpful — and it cannot close indirection
// (`$T send-keys` after `T=tmux`, base64/eval, a helper script that runs tmux, a
// background job, a command split across two sends whose halves never spell the word).
// A remote `ssh host tmux …` is out of scope by policy, not by oversight: another
// machine's session names are not in this registry's namespace. The structural fix is
// a dedicated socket (`tmux -L fin new-session -A -s fin`), which removes the human's
// sessions from the agent's namespace entirely at the cost of being able to READ them.
// See daemon/README.md § "The tmux send-keys guard" for the full residual list.
//
// TWO RULES THIS FILE LEARNED THE HARD WAY, both from real tmux 3.6a on a private
// socket, both places where the first version was wrong:
//   1. SHELL QUOTING IS NOT EVIDENCE. The shell removes quotes before tmux sees argv, so
//      `';'` is a command separator, `"-t"` is a flag, and `t\mux` is tmux. Decide on
//      lexed words, never on the raw string or on `wasQuoted`.
//   2. A TARGET IS NOT ALWAYS A TARGET. `kill-session -a -t fin` kills everything EXCEPT
//      `fin`; `send-keys -c <client>` has no session target at all. Flags that invert or
//      redirect the target are refused before the allow-list is consulted.
//
// THE POLICY, in one line: read anything, write only what is registered.

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

/// Which tmux *server* a command would reach. `-L name` / `-S path` pick a different
/// one; absent both, tmux uses `$TMUX` from inside a session — i.e. the agent's own.
public enum TmuxSocket: Equatable, Sendable {
    case standard
    case name(String)
    case path(String)

    var described: String {
        switch self {
        case .standard: return "the default socket"
        case .name(let value): return "-L \(value)"
        case .path(let value): return "-S \(value)"
        }
    }
}

/// The host-side policy object the engine holds: WHICH sessions may be mutated, on
/// which server, and whether the guard is enforced here at all.
///
/// `.unenforced` is a NAMED, deliberate value rather than a nil hook (contrast
/// `AgentTurnEngine.onNotify`, where nil legitimately means "no channel"): a guard must
/// never be disarmed by accident. It exists because the app drives an arbitrary SSH
/// session where tmux is optional and the user's own quick-fill session name is
/// literally `main` — enforcing there by default would refuse the user's own terminal.
/// Every fail-closed decision lives in `forHost`: no registry means the allow-list is
/// exactly the agent's own session, never "everything".
public struct TmuxSendGuard: Sendable, Equatable {
    public var isEnforced: Bool
    /// The session the agent's own shell lives in (parsed out of `connectCommand`).
    /// A mutating tmux command with no `-t` targets THIS session.
    public var ownSession: String?
    public var ownSocket: TmuxSocket
    /// The registry's session names, READ ONCE at launch.
    ///
    /// Deliberately a snapshot, not a live file read. `routing-registry.json` is an
    /// ordinary file owned by the same uid as the guarded shell, so re-reading it on
    /// every send would make the allow-list writable BY THE THING IT CONSTRAINS: two
    /// commands the guard never even inspects (a `python3 -c` that appends `{"session":
    /// "main"}`, then `tmux send-keys -t main …`) would be enough. A snapshot means
    /// widening the list needs the user, on the host, and takes effect at the next
    /// launch. The cost — a session registered mid-run is not writable until restart —
    /// is paid by `ownedSessionPrefix`, which lets the agent start and drive sessions in
    /// its own namespace without any file at all.
    public var registrySessions: Set<String>
    public var hasRegistry: Bool
    /// Every name that means THIS machine to `ssh`, collected once at launch: the host's
    /// own hostname (long and short), its `.local` form, and every address its interfaces
    /// answer on. `ssh <other host> tmux …` is out of scope by policy, but `ssh
    /// Levis-iMac.local tmux kill-session -t main` is not another machine — it is the
    /// very tmux server this guard defends, reached under a different name.
    public var localHostAliases: Set<String>

    public init(
        isEnforced: Bool,
        ownSession: String?,
        ownSocket: TmuxSocket = .standard,
        registrySessions: Set<String> = [],
        hasRegistry: Bool = false,
        localHostAliases: Set<String> = []
    ) {
        self.isEnforced = isEnforced
        self.ownSession = ownSession
        self.ownSocket = ownSocket
        self.registrySessions = registrySessions
        self.hasRegistry = hasRegistry
        self.localHostAliases = localHostAliases
    }

    /// The explicit opt-out: a host with no tmux namespace of its own to protect.
    public static let unenforced = TmuxSendGuard(isEnforced: false, ownSession: nil)

    /// The daemon's derivation. Enforced when this host has a tmux session of its own
    /// (a `connectCommand` that attaches one) or a routing registry — either fact means
    /// there is a namespace worth defending. Absent both, the guard stays off and
    /// `send_input` behaves exactly as it did before this file existed.
    public static func forHost(connectCommand: String?, registryFileURL: URL?) -> TmuxSendGuard {
        let own = connectCommand.flatMap { TmuxCommandGuard.ownSessionName(inConnectCommand: $0) }
        let socket = connectCommand.map { TmuxCommandGuard.socket(inConnectCommand: $0) } ?? .standard
        let registry = registryFileURL.flatMap { RegistryDocument.loadIfPresent(at: $0) }
        guard own != nil || registry != nil else { return .unenforced }
        return TmuxSendGuard(
            isEnforced: true,
            ownSession: own,
            ownSocket: socket,
            registrySessions: Set(registry?.sessions.map(\.session) ?? []),
            hasRegistry: registry != nil,
            localHostAliases: TmuxCommandGuard.thisMachineNames()
        )
    }

    /// The allow-list: the agent's own session plus every session registered at launch.
    /// (Sessions in Fin's own `fin-` namespace are allowed too, but by rule rather than
    /// by name — see `TmuxCommandGuard.ownedSessionPrefix`.)
    public func resolved() -> (allowed: Set<String>, hasRegistry: Bool) {
        var sessions = registrySessions
        if let ownSession { sessions.insert(ownSession) }
        return (sessions, hasRegistry)
    }

    public func evaluate(_ input: String) -> TmuxGuardVerdict {
        guard isEnforced else { return .allow }
        // Ahead of `resolved()`: `AgentTurnEngine` is main-actor, and every `git status`
        // the agent types goes through here. A command that cannot possibly be about tmux
        // must not pay for building an allow-list.
        guard TmuxCommandGuard.mightMentionTmux(input) else { return .allow }
        let (allowed, present) = resolved()
        return TmuxCommandGuard.evaluate(
            input,
            allowedSessions: allowed,
            ownSession: ownSession,
            ownSocket: ownSocket,
            hasRegistry: present,
            localHostAliases: localHostAliases
        )
    }

    /// The prompt paragraph that tells the model the guard exists and what it may do
    /// instead — a refusal the model understands beats a refusal it fights.
    public var promptSection: String? {
        guard isEnforced else { return nil }
        let (allowed, present) = resolved()
        return TmuxCommandGuard.promptGuidance(allowedSessions: allowed, hasRegistry: present)
    }
}

/// The pure decision: given a command string and an allow-list, may it be typed?
///
/// Every decision is pure, so the whole policy table is unit-testable as strings. The two
/// facts that must come from the machine — the registry file and the host's own names —
/// are read once at launch by `TmuxSendGuard.forHost` and passed in
/// (`thisMachineNames`/`machineInterfaceAddresses` are the collectors, never consulted
/// during an evaluation).
public enum TmuxCommandGuard {

    // MARK: - Public API

    public static func evaluate(
        _ input: String,
        allowedSessions: Set<String>,
        ownSession: String?,
        ownSocket: TmuxSocket = .standard,
        hasRegistry: Bool = true,
        localHostAliases: Set<String> = []
    ) -> TmuxGuardVerdict {
        // Fast path AND blast-radius bound: a command that never mentions tmux (or a
        // process-killer aimed at it) is not this guard's business, and must behave
        // byte-for-byte as it did before. Everything else pays the parser.
        //
        // The cheap test is on the RAW string, so it must not be the only test: the shell
        // assembles the word out of quoting and escaping (`t\mux`, `tm"u"x`, and on this
        // case-insensitive volume `TMUX`, all verified to run tmux), and none of those
        // contain the substring. So anything carrying a quote or a backslash falls
        // through to the lexer, which normalizes exactly those forms, and the real
        // decision is made on lexed words.
        guard mightMentionTmux(input) else { return .allow }
        let context = Context(
            allowed: allowedSessions,
            ownSession: ownSession,
            ownSocket: ownSocket,
            hasRegistry: hasRegistry,
            localHostAliases: localHostAliases
        )

        // THE GUARD JUDGES THE BYTES THAT ARE TYPED, not the raw tool argument.
        // `AgentTurnEngine` sends `AgentTurnLogic.typedBody(input)` and then a separate
        // `\r`, and its forced pre-classification path appends a `\n` to EVERY command it
        // extracts. Judging the untrimmed argument let that newline disarm the half-line
        // test below: `"tmux ls \\\n"` does not *end* in a backslash, so it was allowed —
        // while the PTY still received `tmux ls \` + Return and sat at PS2 waiting for the
        // next send to complete the command. One normalization, one source.
        let line = AgentTurnLogic.typedBody(input)
        let mentions = mentionsTmux(line)

        // HALF A COMMAND IS NOT A COMMAND. The guard sees one `send_input` at a time, but
        // the PTY concatenates them: `tmux \` (allowed on its own) followed by
        // `send-keys -t main 'rm -rf ~'` (no tmux in it at all) is joined by the shell at
        // its continuation prompt into one forbidden command. Same for a line that leaves
        // a quote open. A fragment that could still BECOME `tmux` (`t\`, `tm\`) counts.
        if endsInLineContinuation(line) || hasUnterminatedQuote(line),
           mentions || trailingWordCouldBecomeTmux(line) {
            return .refuse(halfCommandRefusal(context: context))
        }
        guard mentions else { return .allow }
        return evaluate(line: line, depth: 0, context: context)
    }

    /// The agent's own tmux session, parsed out of its `connectCommand`
    /// (`tmux new-session -A -s fin \; set status off` → `fin`). Pure, so the fail-closed
    /// allow-list survives a missing or corrupt registry with a usable `{fin}`.
    public static func ownSessionName(inConnectCommand command: String) -> String? {
        for invocation in invocations(in: command) {
            for sub in subcommands(of: invocation.arguments) {
                guard let verb = sub.first?.text, let resolution = resolve(verb).command else { continue }
                let arguments = Array(sub.dropFirst())
                let flag: Character
                switch resolution.name {
                case "new-session": flag = "s"
                case "attach-session", "switch-client", "has-session": flag = "t"
                default: continue
                }
                for raw in flagValues(flag, in: arguments) {
                    if case .named(let name) = sessionReference(raw) { return name }
                }
            }
        }
        return nil
    }

    /// Which tmux server the agent's own shell lives on, parsed out of `connectCommand`.
    public static func socket(inConnectCommand command: String) -> TmuxSocket {
        for invocation in invocations(in: command) {
            if let socket = invocation.socket { return socket }
        }
        return .standard
    }

    /// The prompt block the daemon appends when the guard is armed.
    public static func promptGuidance(allowedSessions: Set<String>, hasRegistry: Bool) -> String {
        let names = allowedSessions.sorted()
        let list = names.isEmpty ? "(none)" : names.joined(separator: ", ")
        let example = names.first ?? "<session>"
        let scope = hasRegistry
            ? "Sessions you may act on: \(list)."
            : "There is no routing registry on this host, so the allow-list is fail-closed to your own session: \(list)."
        return """
            tmux guard (enforced in code, not just here): read anything, write only what is \
            registered. \(scope) You may also start and drive any session whose name begins with \
            `\(ownedSessionPrefix)` — that prefix is your own namespace, so when you need a session \
            of your own, `tmux new-session -d -s \(ownedSessionPrefix)<purpose>` and drive that. \
            You cannot widen the list any other way from inside the terminal: adding a session the \
            user already owns takes the user, on this host.

            You MAY inspect ANY tmux session on this machine, registered or not, and you should — \
            that is how you answer "what is running", "what is the status of X", or "what did that \
            session print": `tmux capture-pane -p -t <session>`, `tmux list-sessions`, \
            `tmux list-windows -t <session>`, `tmux list-panes -t <session>`, \
            `tmux has-session -t <session>`, `tmux display-message -p ...`. None of those are \
            blocked, for any session.

            You MAY NOT send keys to, paste into, kill, rename, reconfigure, attach to, or open \
            windows/panes in a session outside that list, and you may not reach another tmux \
            server with `-L`/`-S` or execute through tmux (`run-shell`, `if-shell`, `source-file`, \
            `bind-key`). The send_input tool refuses those before a byte reaches the terminal; the \
            refusal is final, so do not retry, rephrase, or wrap the command in a shell. When you \
            need work done in a session that is not yours, read it with capture-pane and ask the \
            user to register it (e.g. `\(example)` is registered; anything else is not).
            """
    }

    /// Fin's own session namespace. A session named `fin-…` is one the agent started for
    /// itself, so it is writable without appearing in any file — which is what keeps the
    /// router's `start` action alive now that the registry is a launch-time snapshot:
    /// `tmux new-session -d -s fin-build` then `send-keys -t fin-build …` works end to
    /// end, with no path from the terminal to the allow-list. The trade is stated plainly
    /// in daemon/README.md: a human session named `fin-…` would be inside Fin's namespace.
    public static let ownedSessionPrefix = "fin-"

    // MARK: - Policy table

    enum CommandKind: Equatable {
        /// Inspection. Allowed against ANY session, registered or not — load-bearing:
        /// a resident agent that cannot SEE the machine's real work is useless.
        case readOnly
        /// Refused whatever the target is: these execute commands, hijack the human's
        /// client, or reach the whole server.
        case alwaysRefuse(String)
        /// Allowed only when every session it names is in the allow-list. With no `-t`
        /// the target is the agent's own session.
        case targetChecked
        /// `new-session`: creating one is the router's `start` action and must stay
        /// legal, but `-t` (group with an existing session, sharing its windows) and
        /// `-A` + `-s` (attach-or-create, i.e. take over an existing session) are not.
        case newSession
        /// The set-* family: `-g`/`-s` scope escapes the session, so it is refused
        /// before the target check.
        case scopedOption
    }

    struct TmuxCommand: Equatable {
        let name: String
        let aliases: [String]
        let kind: CommandKind

        init(_ name: String, _ aliases: [String] = [], _ kind: CommandKind) {
            self.name = name
            self.aliases = aliases
            self.kind = kind
        }
    }

    /// Deliberately broad, because tmux resolves any UNAMBIGUOUS PREFIX of a command
    /// name. A table that omitted `kill-server` would let `kill-s` resolve to
    /// `kill-session` here and to something else in real tmux, so the dangerous verbs
    /// are all present precisely so short prefixes collide and fail closed.
    ///
    /// Diffed against `tmux -L <private> -f /dev/null list-commands` on tmux 3.6a: every
    /// name and alias below matches, the table covers all 90 real commands, and no
    /// prefix of a real command resolves to a `.readOnly` entry here that real tmux would
    /// resolve to something else. `server-info` is retained for older tmux, which is
    /// harmless — an extra read-only name cannot widen anything.
    static let commands: [TmuxCommand] = [
        // ---- read-only: inspection of any session, always allowed ----
        TmuxCommand("capture-pane", ["capturep"], .readOnly),
        TmuxCommand("display-message", ["display"], .readOnly),
        TmuxCommand("has-session", ["has"], .readOnly),
        TmuxCommand("list-buffers", ["lsb"], .readOnly),
        TmuxCommand("list-clients", ["lsc"], .readOnly),
        TmuxCommand("list-commands", ["lscm"], .readOnly),
        TmuxCommand("list-keys", ["lsk"], .readOnly),
        TmuxCommand("list-panes", ["lsp"], .readOnly),
        TmuxCommand("list-sessions", ["ls"], .readOnly),
        TmuxCommand("list-windows", ["lsw"], .readOnly),
        TmuxCommand("server-info", ["info"], .readOnly),
        TmuxCommand("show-buffer", ["showb"], .readOnly),
        TmuxCommand("show-environment", ["showenv"], .readOnly),
        TmuxCommand("show-hooks", [], .readOnly),
        TmuxCommand("show-messages", ["showmsgs"], .readOnly),
        TmuxCommand("show-options", ["show"], .readOnly),
        TmuxCommand("show-prompt-history", ["showphist"], .readOnly),
        TmuxCommand("show-window-options", ["showw"], .readOnly),

        // ---- always refused: execution, whole-server reach, client hijack ----
        TmuxCommand("kill-server", [], .alwaysRefuse("`kill-server` destroys every tmux session on this machine, including sessions that are not Fin's.")),
        TmuxCommand("run-shell", ["run"], .alwaysRefuse("`run-shell` executes a shell command through the tmux server, outside any target check.")),
        TmuxCommand("if-shell", ["if"], .alwaysRefuse("`if-shell` executes shell and tmux commands, outside any target check.")),
        TmuxCommand("source-file", ["source"], .alwaysRefuse("`source-file` runs whatever tmux commands a file contains, so it can rewrite the guard's own assumptions.")),
        TmuxCommand("bind-key", ["bind"], .alwaysRefuse("`bind-key` installs a keybinding that can execute commands later, in any session.")),
        TmuxCommand("unbind-key", ["unbind"], .alwaysRefuse("`unbind-key` rewrites the human's key bindings server-wide.")),
        TmuxCommand("set-hook", [], .alwaysRefuse("`set-hook` installs a command that fires later, outside any target check.")),
        TmuxCommand("command-prompt", [], .alwaysRefuse("`command-prompt` executes a command template in the human's own client.")),
        TmuxCommand("confirm-before", ["confirm"], .alwaysRefuse("`confirm-before` executes a command template in the human's own client.")),
        TmuxCommand("display-menu", ["menu"], .alwaysRefuse("`display-menu` executes a command template in the human's own client.")),
        TmuxCommand("display-popup", ["popup"], .alwaysRefuse("`display-popup` runs a command in a popup over the human's own client.")),
        TmuxCommand("display-panes", ["displayp"], .alwaysRefuse("`display-panes` executes a command template against a pane the human picks.")),
        TmuxCommand("choose-buffer", [], .alwaysRefuse("`choose-buffer` executes a command template in the human's own client.")),
        TmuxCommand("choose-client", [], .alwaysRefuse("`choose-client` executes a command template in the human's own client.")),
        TmuxCommand("choose-tree", [], .alwaysRefuse("`choose-tree` executes a command template in the human's own client.")),
        TmuxCommand("customize-mode", [], .alwaysRefuse("`customize-mode` edits options interactively in the human's own client.")),
        TmuxCommand("attach-session", ["attach"], .alwaysRefuse("`attach-session` takes over a terminal — it moves a client, which is the human's, not Fin's.")),
        TmuxCommand("switch-client", ["switchc"], .alwaysRefuse("`switch-client` moves the human's attached client to another session.")),
        TmuxCommand("detach-client", ["detach"], .alwaysRefuse("`detach-client` disconnects the human's attached client.")),
        TmuxCommand("suspend-client", ["suspendc"], .alwaysRefuse("`suspend-client` suspends the human's attached client.")),
        TmuxCommand("refresh-client", ["refresh"], .alwaysRefuse("`refresh-client` reaches into an attached client, which is the human's, not Fin's.")),
        TmuxCommand("lock-server", ["lock"], .alwaysRefuse("`lock-server` locks every client on this machine.")),
        TmuxCommand("lock-client", ["lockc"], .alwaysRefuse("`lock-client` locks the human's attached client.")),
        TmuxCommand("lock-session", ["locks"], .alwaysRefuse("`lock-session` locks the clients attached to a session.")),
        TmuxCommand("server-access", [], .alwaysRefuse("`server-access` changes who may reach this tmux server.")),
        TmuxCommand("clear-prompt-history", ["clearphist"], .alwaysRefuse("`clear-prompt-history` rewrites server-wide state that belongs to the human's client.")),
        TmuxCommand("wait-for", ["wait"], .alwaysRefuse("`wait-for` can block Fin's own shell indefinitely on a channel nothing will signal.")),

        // ---- the set-* family: -g/-s escape the session ----
        TmuxCommand("set-option", ["set"], .scopedOption),
        TmuxCommand("set-window-option", ["setw"], .scopedOption),
        TmuxCommand("set-environment", ["setenv"], .scopedOption),

        // ---- session creation ----
        TmuxCommand("new-session", ["new"], .newSession),

        // ---- everything else that mutates: allowed only against a registered target ----
        TmuxCommand("send-keys", ["send"], .targetChecked),
        TmuxCommand("send-prefix", [], .targetChecked),
        TmuxCommand("paste-buffer", ["pasteb"], .targetChecked),
        TmuxCommand("set-buffer", ["setb"], .targetChecked),
        TmuxCommand("load-buffer", ["loadb"], .targetChecked),
        TmuxCommand("save-buffer", ["saveb"], .targetChecked),
        TmuxCommand("delete-buffer", ["deleteb"], .targetChecked),
        TmuxCommand("kill-session", [], .targetChecked),
        TmuxCommand("kill-window", ["killw"], .targetChecked),
        TmuxCommand("kill-pane", ["killp"], .targetChecked),
        TmuxCommand("new-window", ["neww"], .targetChecked),
        TmuxCommand("split-window", ["splitw"], .targetChecked),
        TmuxCommand("respawn-pane", ["respawnp"], .targetChecked),
        TmuxCommand("respawn-window", ["respawnw"], .targetChecked),
        TmuxCommand("swap-pane", ["swapp"], .targetChecked),
        TmuxCommand("swap-window", ["swapw"], .targetChecked),
        TmuxCommand("move-pane", ["movep"], .targetChecked),
        TmuxCommand("move-window", ["movew"], .targetChecked),
        TmuxCommand("join-pane", ["joinp"], .targetChecked),
        TmuxCommand("break-pane", ["breakp"], .targetChecked),
        TmuxCommand("link-window", ["linkw"], .targetChecked),
        TmuxCommand("unlink-window", ["unlinkw"], .targetChecked),
        TmuxCommand("rename-session", ["rename"], .targetChecked),
        TmuxCommand("rename-window", ["renamew"], .targetChecked),
        TmuxCommand("select-pane", ["selectp"], .targetChecked),
        TmuxCommand("select-window", ["selectw"], .targetChecked),
        TmuxCommand("select-layout", ["selectl"], .targetChecked),
        TmuxCommand("next-window", ["next"], .targetChecked),
        TmuxCommand("previous-window", ["prev"], .targetChecked),
        TmuxCommand("last-window", ["last"], .targetChecked),
        TmuxCommand("last-pane", ["lastp"], .targetChecked),
        TmuxCommand("next-layout", ["nextl"], .targetChecked),
        TmuxCommand("previous-layout", ["prevl"], .targetChecked),
        TmuxCommand("rotate-window", ["rotatew"], .targetChecked),
        TmuxCommand("resize-pane", ["resizep"], .targetChecked),
        TmuxCommand("resize-window", ["resizew"], .targetChecked),
        TmuxCommand("clear-history", ["clearhist"], .targetChecked),
        TmuxCommand("copy-mode", [], .targetChecked),
        TmuxCommand("clock-mode", [], .targetChecked),
        TmuxCommand("find-window", ["findw"], .targetChecked),
        TmuxCommand("pipe-pane", ["pipep"], .targetChecked),
        TmuxCommand("start-server", ["start"], .targetChecked),
    ]

    /// Wrappers whose FIRST word is not the real command, so the tail has to be
    /// re-scanned for a tmux invocation (`ssh box tmux …`, `xargs tmux …`) and whose
    /// QUOTED arguments are program text they will run rather than data.
    ///
    /// The inline interpreters are here for the second reason only. `python3 -c "…
    /// subprocess.run('tmux send-keys -t main …', shell=True)"` is not indirection and
    /// nothing is assembled at runtime — the word `tmux` and its target sit in plain sight
    /// in a single send — so leaving them out meant a reader who saw `sh -c` closed would
    /// wrongly assume the class was closed. Their payloads are unwrapped with the same
    /// lexer as a shell's, which catches the spellings that contain a tmux COMMAND LINE —
    /// `os.system("tmux kill-server")`, `system("tmux …")`, `execSync("tmux …")`,
    /// `do shell script "tmux …"`, `subprocess.run("tmux …", shell=True)`. It does NOT
    /// catch an argv built structurally (`subprocess.run(["tmux", "send-keys", …])`),
    /// where no word is ever a command line; that shape is in the residual list in
    /// daemon/README.md with the rest of the runtime assembly.
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

    /// Not tmux commands at all, but they end the same way `kill-server` does.
    static let processKillers: Set<String> = ["pkill", "killall"]

    private static let maxNestingDepth = 3

    // MARK: - Context

    struct Context {
        var allowed: Set<String>
        var ownSession: String?
        var ownSocket: TmuxSocket
        var hasRegistry: Bool
        /// Names that mean "this machine" to ssh, beyond the universal loopback spellings.
        var localHostAliases: Set<String> = []
    }

    // MARK: - Evaluation

    static func evaluate(line: String, depth: Int, context: Context) -> TmuxGuardVerdict {
        let all = segments(in: line)
        // `evaluate(line:)` is only ever reached for a line that mentions tmux, so a shell
        // in that line with nothing to run is a shell that will run what the pipe hands
        // it: `echo tmux kill-server | sh`, `printf 'tmux send-keys -t main …\n' | bash`.
        // Exactly the stdin-invisibility `xargs tmux` is refused for — the guard can see
        // the words but not which of them the shell will execute — so it gets the same
        // answer rather than a parse.
        if let shell = all.first(where: { isShellReadingItsCommandsFromStdin($0) }) {
            return refusal(
                "`\(normalized(basename(shell[0].text)))` with no script and no `-c` runs whatever "
                    + "arrives on its stdin, and this line builds tmux text on the other side of the "
                    + "pipe — the same blind spot as `xargs tmux`, so it cannot be target-checked. "
                    + "Run the tmux command directly instead.",
                session: nil,
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
        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh"]
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
              shells.contains(normalized(basename(segment[index].text))) else { return false }
        for word in segment[(index + 1)...] {
            guard word.text.hasPrefix("-"), word.text.count > 1 else { return false }
            if word.text.dropFirst().contains("c") { return false }
        }
        return true
    }

    private static func evaluate(segment words: [Word], depth: Int, context: Context) -> TmuxGuardVerdict {
        guard !words.isEmpty else { return .allow }

        // Strip `sudo`/`env FOO=1`/`exec`… to find the real head FIRST: every decision
        // below (does this head execute its quoted arguments? is it an ssh hop?) is about
        // the command that will actually run, not the wrapper.
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

        // A REMOTE hop leaves this guard's world. `worker` on the cloud box is not
        // `worker` here, and this registry says nothing about that machine — checking it
        // against a local allow-list refuses legitimate work (driving Fin's own cloud box
        // over ssh is a documented product behavior) without protecting anything local.
        // Exactly the reasoning `-L`/`-S` already gets. `ssh localhost …` IS local.
        if head == "ssh", !sshRunsOnThisMachine(tail, localAliases: context.localHostAliases) {
            return .allow
        }

        // `xargs` builds tmux's argv out of stdin, which this guard cannot see:
        // `echo "rename-session -t main OWNED" | xargs tmux` renamed a session on a probe
        // socket while the guard saw an argument-less `tmux`. Refuse the combination.
        if head == "xargs", tail.contains(where: { isTmuxToken($0.text) }) {
            return refusal(
                "`xargs tmux` builds tmux's arguments out of stdin, which Fin's guard cannot see, "
                    + "so the target check cannot be applied at all. Write the tmux command out in "
                    + "full on one line instead.",
                session: nil,
                context: context
            )
        }

        // A quoted argument can be its own little command line — but ONLY when the head is
        // something that RUNS it: `sh -c '…'`, `eval "…"`, an inline interpreter's `-c`/
        // `-e` payload, or tmux itself relaying a payload into another session (the
        // two-hop `tmux send-keys -t fin 'tmux … -t main'`). Text that merely mentions
        // tmux — `git commit -m "tmux guard: …"`, `grep "tmux kill-server" daemon/`,
        // `echo "tmux …" >> notes.md` — is data, and refusing it cost real work.
        //
        // `depth > 0` is the third case and it is deliberate: below the top level we are
        // ALREADY inside text some runner will execute, so every quoted word in it is
        // program text too. That is what reaches the tmux inside
        // `awk 'BEGIN{system("tmux kill-server")}'` and `python3 -c 'os.system("tmux …")'`,
        // where the payload's own head (`os.system`) means nothing to this parser. The
        // cost is a false refusal for a payload that merely quotes a tmux command
        // (`sh -c 'echo "tmux kill-server" >> notes'`), which is the safe direction and is
        // documented.
        if head == "tmux" || commandCarriers.contains(head) || depth > 0 {
            for word in words[index...] where word.wasQuoted && mentionsTmux(word.text, depth: depth + 1) {
                guard depth < maxNestingDepth else {
                    return refusal(
                        "that command nests tmux inside quoted shell text more deeply than Fin's "
                            + "guard will unwrap, so it cannot be proven read-only.",
                        session: nil,
                        context: context
                    )
                }
                let verdict = evaluate(line: word.text, depth: depth + 1, context: context)
                if verdict.isRefusal { return verdict }
            }
        }

        if head == "tmux" {
            // `strict` — an unrecognized verb is a refusal — only at the top level, where
            // the word `tmux` really is the command. Deeper down (quoted payloads, a verb
            // fished out of a carrier's arguments) an unknown verb is prose or an
            // argument: real tmux would answer "unknown command" and do nothing.
            return evaluate(invocation: tail, depth: depth, context: context, strict: depth == 0)
        }

        if processKillers.contains(head), tail.contains(where: { normalized($0.text).contains("tmux") }) {
            return refusal(
                "`\(head)` aimed at tmux would kill the tmux server and every session on it, "
                    + "including sessions that are not Fin's.",
                session: nil,
                context: context
            )
        }

        // `ssh localhost tmux …`, `sudo -u someone tmux …`, `timeout 60 tmux …`: the
        // command word is at an offset we can't compute, so scan for it.
        if commandCarriers.contains(head) || strippedPrefix {
            if let hit = tail.firstIndex(where: { isTmuxToken($0.text) }) {
                return evaluate(
                    invocation: Array(tail[(hit + 1)...]),
                    depth: depth,
                    context: context,
                    strict: false
                )
            }
        }

        // LAST RESORT: the word `tmux` in plain sight under a head this parser does not
        // model. Every wrapper list above is a list of things we happen to have thought
        // of, and the ways past it were not exotic — all four verified on a private
        // socket: `find . -maxdepth 0 -exec tmux send-keys -t main 'rm -rf ~' Enter \;`
        // (an exec wrapper), `if tmux kill-server; then :; fi` and `for i in 1; do tmux
        // kill-session -t main; done` (shell KEYWORDS, which are neither a command nor a
        // prefix this parser strips), and `echo tmux kill-server | sh` (a pipeline whose
        // right side reads the left side's stdout — the same stdin-invisibility `xargs
        // tmux` is refused for). In all of them the head is unrecognized, so nothing can
        // be proven about how it treats its arguments, and the pessimistic reading is the
        // only honest one.
        //
        // Two things keep this from refusing ordinary work. Only a BARE token counts, so
        // prose keeps the word inside a quoted word (`grep "tmux kill-server" daemon/`,
        // `git commit -m "tmux guard: …"`). And the verb is resolved leniently, so
        // `man tmux`, `brew install tmux`, `which tmux` and `sudo grep tmux /etc/shells`
        // — where what follows the word is not a tmux command — stay allowed.
        if let hit = tail.firstIndex(where: { isTmuxToken($0.text) && !$0.wasQuoted }) {
            return evaluate(
                invocation: Array(tail[(hit + 1)...]),
                depth: depth,
                context: context,
                strict: false
            )
        }

        return .allow
    }

    /// One `tmux …` invocation: global flags, then one or more `;`-separated commands.
    private static func evaluate(
        invocation args: [Word],
        depth: Int,
        context: Context,
        strict: Bool
    ) -> TmuxGuardVerdict {
        let parsed = parseGlobalFlags(args)
        if let refusalText = parsed.refusal {
            return refusal(refusalText, session: nil, context: context)
        }
        // A `-L`/`-S` that names another server puts the whole allow-list out of scope:
        // "fin" over there is a different session than "fin" here. Reading stays legal
        // (read anything), so the check lands per-command, after the verb is classified.
        let socketMismatch = parsed.socket.map { $0 != context.ownSocket } ?? false

        for sub in subcommands(of: parsed.arguments) {
            let verdict = evaluate(
                command: sub,
                socket: parsed.socket,
                socketMismatch: socketMismatch,
                deferredRefusal: parsed.deferredRefusal,
                depth: depth,
                context: context,
                strict: strict
            )
            if verdict.isRefusal { return verdict }
        }
        return .allow
    }

    private static func evaluate(
        command words: [Word],
        socket: TmuxSocket?,
        socketMismatch: Bool,
        deferredRefusal: String?,
        depth: Int,
        context: Context,
        strict: Bool
    ) -> TmuxGuardVerdict {
        // Bare `tmux` (or a trailing `;`): new-session with a generated name. It touches
        // nothing that already exists.
        guard let verb = words.first?.text else { return .allow }
        let arguments = Array(words.dropFirst())

        let resolution = resolve(verb)
        guard let command = resolution.command else {
            guard strict else { return .allow }
            return refusal(
                "Fin's guard does not recognize the tmux command `\(verb)`, so it cannot prove the "
                    + "command only reads. Unrecognized tmux commands are refused, not guessed at.",
                session: nil,
                context: context
            )
        }

        // Inspection first: reading is allowed on any session and any server — including
        // under a global flag that would otherwise be refused, so `tmux -f /dev/null ls`
        // still reads.
        if case .readOnly = command.kind { return .allow }
        if let deferredRefusal {
            return refusal(deferredRefusal, session: nil, context: context)
        }
        if socketMismatch, let socket {
            return refusal(
                "`\(command.name)` names an explicit tmux server (\(socket.described)), which is "
                    + "not the one Fin runs on (\(context.ownSocket.described)) — session names on "
                    + "another socket mean nothing to Fin's allow-list.",
                session: nil,
                context: context
            )
        }

        switch command.kind {
        case .readOnly:
            return .allow

        case .alwaysRefuse(let why):
            return refusal(why, session: nil, context: context)

        case .scopedOption:
            if hasFlag("g", in: arguments) || hasFlag("s", in: arguments) {
                return refusal(
                    "`\(command.name) -g`/`-s` sets a global or server-wide option, which reaches "
                        + "sessions that are not Fin's.",
                    session: nil,
                    context: context
                )
            }
            return check(targets: flagValues("t", in: arguments), command: command.name, context: context)

        case .targetChecked:
            if let why = targetIsNotWhatItSays(command: command.name, arguments: arguments) {
                return refusal(why, session: nil, context: context)
            }
            // `-s` is a SOURCE session/window/pane on swap/move/join/link/break/copy-mode,
            // so it is checked like `-t` — with one exception verified against 3.6a's own
            // usage line: `paste-buffer [-dpr] [-s separator] [-b buffer-name]
            // [-t target-pane]`, where `-s` is a literal separator string. Reading it as a
            // target refused `tmux paste-buffer -s ' ' -t fin` — a paste into Fin's OWN
            // session — while naming a "session" that was never one.
            var targets = flagValues("t", in: arguments)
            if command.name != "paste-buffer" {
                targets += flagValues("s", in: arguments)
            }
            return check(targets: targets, command: command.name, context: context)

        case .newSession:
            // Creating a fresh session is the router's `start` action and stays legal.
            // Grouping onto an existing session shares its windows; `-A` attaches to one
            // that already exists. Both are ways to reach somebody else's session.
            var targets = flagValues("t", in: arguments)
            if hasFlag("A", in: arguments) {
                targets += flagValues("s", in: arguments)
            }
            guard !targets.isEmpty else { return .allow }
            return check(targets: targets, command: command.name, context: context)
        }
    }

    /// Flags that make `-t` mean something OTHER than "this one session", which is the
    /// only thing `check(targets:)` knows how to reason about. Both were verified on
    /// tmux 3.6a against a private socket:
    ///
    /// - `kill-session -a -t fin` kills every session EXCEPT `fin` (sessions fin/main/
    ///   bystander before, only `fin` after). An allow-listed target is exactly what makes
    ///   it dangerous: its blast radius is `kill-server`'s, which the table refuses.
    /// - `send-keys -c <client-tty>` (and `-K`) types into whatever session a CLIENT is
    ///   attached to — `tmux list-clients` is an allowed read that prints those ttys, and
    ///   on this host the attached client is the human's. There is no `-t` to check.
    static func targetIsNotWhatItSays(command: String, arguments: [Word]) -> String? {
        if command == "kill-session", hasFlag("a", in: arguments) {
            return "`kill-session -a` kills every session on this server EXCEPT the one it names, "
                + "so naming an allowed session is what makes it dangerous — it has `kill-server`'s "
                + "blast radius. Kill one session at a time, by name, with no `-a`."
        }
        if command == "send-keys" || command == "send-prefix",
           hasFlag("c", in: arguments) || hasFlag("K", in: arguments) {
            return "`\(command) -c`/`-K` sends keys to a CLIENT rather than to a named session, so "
                + "they land in whatever session that client is attached to — which on this machine "
                + "is the human's terminal. Address a session with `-t <session>` instead."
        }
        return nil
    }

    /// The allow-list test. A name is Fin's if it was registered at launch, if it is the
    /// agent's own session, or if it lives in Fin's own `fin-` namespace.
    static func isAllowed(_ name: String, in context: Context) -> Bool {
        context.allowed.contains(name) || name.hasPrefix(ownedSessionPrefix)
    }

    private static func check(targets: [String], command: String, context: Context) -> TmuxGuardVerdict {
        guard !targets.isEmpty else {
            // No `-t`: tmux acts on the CURRENT session, which is the agent's own.
            guard let own = context.ownSession else {
                return refusal(
                    "`\(command)` with no `-t` acts on whatever session Fin's own shell is in, and "
                        + "Fin does not know that session's name on this host, so it cannot prove "
                        + "the command stays inside its own namespace.",
                    session: nil,
                    context: context
                )
            }
            guard isAllowed(own, in: context) else {
                return refusal(
                    "`\(command)` with no `-t` acts on Fin's own session \"\(own)\", which is not in "
                        + "the allow-list.",
                    session: own,
                    context: context
                )
            }
            return .allow
        }

        for target in targets {
            switch sessionReference(target) {
            case .current:
                guard let own = context.ownSession, isAllowed(own, in: context) else {
                    return refusal(
                        "`\(command)` targets the current session, which Fin cannot resolve to an "
                            + "allowed session name on this host.",
                        session: context.ownSession,
                        context: context
                    )
                }
            case .named(let name):
                guard isAllowed(name, in: context) else {
                    return refusal(
                        "`\(command)` would act on tmux session \"\(name)\", which is not a session "
                            + "Fin is registered to drive.",
                        session: name,
                        context: context
                    )
                }
            case .unresolvable(let raw):
                return refusal(
                    "`\(command)` targets \"\(raw)\", which does not name a session Fin can resolve "
                        + "(a pane/window id, an index, or a pattern can point at any session on the "
                        + "server). Name the session explicitly, e.g. `-t \(context.ownSession ?? "<session>")`.",
                    session: nil,
                    context: context
                )
            }
        }
        return .allow
    }

    // MARK: - Refusal text

    /// The refusal the MODEL reads. Its job is to end the attempt and redirect it:
    /// `send_input`'s own description tells the model not to ask before acting, so a
    /// vague refusal just gets retried. Hence: what was blocked, that it is final, what
    /// is still allowed (reading — with real commands to copy), and who can widen it.
    static func refusal(_ headline: String, session: String?, context: Context) -> TmuxGuardVerdict {
        let sorted = context.allowed.sorted()
        let list = sorted.isEmpty ? "(none)" : sorted.joined(separator: ", ")
        let example = session ?? sorted.first ?? "<session>"
        var parts: [String] = []
        parts.append(
            "REFUSED by Fin's tmux guard: \(headline) Nothing was typed into the terminal. "
                + "This is a gate in code, not a preference — do not retry it, rephrase it, or wrap "
                + "it in a shell."
        )
        parts.append(
            "You MAY read any tmux session on this machine, registered or not, and you should: "
                + "`tmux capture-pane -p -t \(example)`, `tmux list-sessions`, "
                + "`tmux list-windows -t \(example)`, `tmux list-panes -t \(example)`, "
                + "`tmux has-session -t \(example)`, `tmux display-message -p ...` all run "
                + "unimpeded. That is how you report on work that is not yours."
        )
        parts.append(
            "You MAY NOT send keys to, paste into, kill, rename, reconfigure, attach to, or open "
                + "windows/panes in a session outside the allow-list."
        )
        if context.hasRegistry {
            parts.append("Sessions you may act on right now: \(list).")
        } else {
            parts.append(
                "There is no routing registry on this host, so the allow-list is fail-closed to "
                    + "Fin's own session: \(list)."
            )
        }
        // Deliberately does NOT name the registry file. The allow-list is a launch-time
        // snapshot precisely so the guarded shell cannot widen it; printing the path here
        // would hand the model the one lever the snapshot exists to remove.
        parts.append(
            "You cannot widen this list from the terminal. If you need a session of your own, start "
                + "one in Fin's namespace — `tmux new-session -d -s \(ownedSessionPrefix)work` — and "
                + "drive that; those are always yours."
        )
        // The one legitimate shape this guard cannot tell from a command: a tmux command
        // line that is FILE CONTENT (a here-doc body, a doc, a script being written).
        // Nothing executes it, but the parser sees the same words, and "do not rephrase"
        // would otherwise dead-end a documentation task in a repo whose current work is
        // this guard. So the refusal names the way through.
        parts.append(
            "If you were WRITING this line into a file rather than running it, do not use a here-doc "
                + "— Fin's guard cannot tell a here-doc body from a command. Write it with a quoted "
                + "argument instead, e.g. `printf 'tmux send-keys -t x hi\\n' >> notes.md`, which is "
                + "allowed because the tmux text is data there."
        )
        if let session {
            parts.append(
                "Driving \"\(session)\" takes the user registering it on this host, which applies the "
                    + "next time the agent starts — tell them that, and offer to read the session "
                    + "instead."
            )
        }
        return .refuse(parts.joined(separator: " "))
    }

    /// The half-typed line gets its OWN refusal, because the standard one is wrong here in
    /// both directions: it says "do not retry or rephrase" when re-sending the command
    /// joined onto one line is exactly the right move, and it offers `capture-pane` as the
    /// alternative when the thing refused may BE a capture-pane split over two lines
    /// (the read half is unconditionally allowed everywhere else, and this is the one
    /// place it is not — a continuation cannot be classified, because the verb it will
    /// finally carry has not been typed yet).
    static func halfCommandRefusal(context: Context) -> String {
        let sorted = context.allowed.sorted()
        let example = sorted.first ?? "<session>"
        return "REFUSED by Fin's tmux guard: that line is only half a command — it ends in a shell "
            + "continuation (`\\`) or an unterminated quote, so what it finally runs depends on the "
            + "next thing typed, and Fin's guard judges one send at a time. Nothing was typed into "
            + "the terminal. This is the one refusal you SHOULD retry: send the whole command in a "
            + "single send_input, on one line, and it will be judged on what it actually does. That "
            + "applies to reads too — `tmux capture-pane -p -t \(example)` is always allowed, but "
            + "send it as one unbroken line."
    }

    // MARK: - Command resolution

    struct Resolution {
        var command: TmuxCommand?
        var ambiguous: Bool
    }

    /// tmux accepts any unambiguous prefix, so `send`, `send-key`, `kill-ses` all work.
    /// Exact name or alias wins; otherwise every prefix match votes and the MOST
    /// RESTRICTIVE class wins, so a short prefix can never be laundered into a
    /// read-only classification by a table that happens to be incomplete.
    ///
    /// tmux prefix-matches ALIASES as well as names (cmd_find in cmd.c compares both), so
    /// this does too — otherwise `showe` and `showms`, which are real ways to spell
    /// `show-environment` and `show-messages`, come back as unknown verbs and read-only
    /// inspection gets refused for no reason.
    static func resolve(_ verb: String) -> Resolution {
        guard !verb.isEmpty else { return Resolution(command: nil, ambiguous: false) }
        if let exact = commands.first(where: { $0.name == verb || $0.aliases.contains(verb) }) {
            return Resolution(command: exact, ambiguous: false)
        }
        let matches = commands.filter { command in
            command.name.hasPrefix(verb) || command.aliases.contains { $0.hasPrefix(verb) }
        }
        guard !matches.isEmpty else { return Resolution(command: nil, ambiguous: false) }
        if matches.count == 1 { return Resolution(command: matches[0], ambiguous: false) }
        if let refused = matches.first(where: { if case .alwaysRefuse = $0.kind { return true }; return false }) {
            return Resolution(command: refused, ambiguous: true)
        }
        if let mutating = matches.first(where: { $0.kind != .readOnly }) {
            // Downgrade to the plain target check: `-t`/`-s` are what every mutating
            // command in this set is gated on anyway.
            return Resolution(
                command: TmuxCommand(mutating.name, [], .targetChecked),
                ambiguous: true
            )
        }
        return Resolution(command: matches[0], ambiguous: true)
    }

    // MARK: - tmux argument parsing

    struct ParsedInvocation {
        var socket: TmuxSocket?
        var arguments: [Word]
        var refusal: String?
        /// Applied only to commands that are not read-only, the same way a socket
        /// mismatch is: `tmux -f /dev/null list-sessions` is still just a read.
        var deferredRefusal: String?
    }

    /// tmux's global flags: `tmux [-2CDlNuVv] [-c shell-command] [-f file] [-L socket-name]
    /// [-S socket-path] [-T features] [command …]`.
    ///
    /// GETOPT CLUSTERS, HERE TOO. This used to read `letters[0]` only, so a value-taking
    /// flag anywhere but first was skipped and ITS VALUE became the verb: `tmux -2f ls
    /// send-keys -t main 'rm -rf ~' Enter` parsed as the read-only `ls` and the whole
    /// mutation — the entire rest of argv — was never examined. Real tmux reads it as
    /// `-2`, `-f ls`, then `send-keys …`, and on a private socket it really did deliver
    /// the keys (a missing `-f` file is not fatal, so nothing has to exist first). Same
    /// bug, and the same fix, as `flagValues`: scan the whole cluster, and the first
    /// value-taking letter consumes the rest of the cluster or the next argument.
    ///
    /// The index arithmetic is the other half. A value flag in LAST position used to
    /// advance `index` twice — once inside the case, once at the loop bottom — so a bare
    /// `tmux -f` walked off the end and `args[index...]` trapped. A four-character
    /// `send_input` crashed the daemon, which is the one thing the guard's contract
    /// ("an honest tool result the model can read and recover from — never a crash")
    /// promises it will not do.
    static func parseGlobalFlags(_ args: [Word]) -> ParsedInvocation {
        var socket: TmuxSocket?
        var deferred: String?
        var index = 0
        while index < args.count {
            let token = args[index].text
            guard token.hasPrefix("-"), token.count > 1 else { break }
            let letters = Array(token.dropFirst())
            var position = 0
            while position < letters.count {
                let key = letters[position]
                guard key == "L" || key == "S" || key == "f" || key == "c" || key == "T" else {
                    position += 1
                    continue
                }
                var value = String(letters[(position + 1)...])
                if value.isEmpty, index + 1 < args.count {
                    index += 1
                    value = args[index].text
                }
                switch key {
                case "L": socket = .name(value)
                case "S": socket = .path(value)
                case "c":
                    return ParsedInvocation(
                        socket: socket, arguments: [],
                        refusal: "`tmux -c` runs a shell command through the tmux server, outside any target check."
                    )
                case "f":
                    deferred = "`tmux -f` loads an alternate config file, which can bind keys that execute commands."
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
            refusal: nil,
            deferredRefusal: deferred
        )
    }

    /// tmux's own multi-command form: `tmux a \; b`.
    ///
    /// SHELL QUOTING CANNOT BE CONSULTED HERE. The shell removes quotes before tmux sees
    /// argv, so `\;`, `';'` and `";"` are byte-identical arguments and tmux separates on
    /// all three. tmux's actual rule (`cmd_parse_from_arguments`) is: an argument that
    /// ends in `;` ends the command, unless that `;` is itself backslash-escaped, in which
    /// case it is a literal. Verified on tmux 3.6a, private socket:
    /// `tmux ls ';' rename-session -t other x` renamed `other`, and
    /// `tmux send-keys -t fin 'echo hi;' Enter` answered "unknown command: Enter" — i.e.
    /// real tmux splits the quoted payload too, so mirroring it is not a false refusal.
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

    /// Every value given to `-<flag>`, in the separated (`-t main`), attached (`-tmain`)
    /// and CLUSTERED (`-lt main`, `-dt main`, `-As main`) forms. ALL of them are checked:
    /// a literal argument that merely looks like `-t` costs a false refusal, which is the
    /// safe direction.
    ///
    /// Two rules learned the hard way, both verified against tmux 3.6a on a private
    /// socket. (1) tmux uses getopt, which packs short options: `send-keys -lt victim x`
    /// really does deliver to `victim`, and `kill-session -at fin` really does kill every
    /// other session — so the flag letter must be looked for anywhere in the cluster, not
    /// just first. (2) Shell quoting says nothing about what is a flag: the shell strips
    /// quotes before tmux sees argv, and `send-keys '-t' victim x` delivers exactly like
    /// `send-keys -t victim x`. So `wasQuoted` is NOT consulted.
    static func flagValues(_ flag: Character, in args: [Word]) -> [String] {
        var values: [String] = []
        var index = 0
        while index < args.count {
            let token = args[index].text
            if token.hasPrefix("-"), !token.hasPrefix("--"), token.count > 1 {
                let letters = Array(token.dropFirst())
                if let position = letters.firstIndex(of: flag) {
                    let attached = String(letters[(position + 1)...])
                    if attached.isEmpty {
                        index += 1
                        // A dangling flag has no value we can resolve — the sentinel
                        // falls through `sessionReference` as unresolvable.
                        values.append(index < args.count ? args[index].text : "\u{0}")
                    } else {
                        values.append(attached)
                    }
                }
            }
            index += 1
        }
        return values
    }

    /// Same two rules as `flagValues`: scan the whole cluster, ignore shell quoting.
    /// `set-option "-g" default-command …` is a server-wide option however it was quoted.
    static func hasFlag(_ letter: Character, in args: [Word]) -> Bool {
        args.contains { word in
            guard word.text.hasPrefix("-"), !word.text.hasPrefix("--") else { return false }
            return word.text.dropFirst().contains(letter)
        }
    }

    enum SessionReference: Equatable {
        case named(String)
        /// No target, or a target whose session part is empty — tmux's current session.
        case current
        /// A pane/window id, an index, or a pattern: it can point into ANY session, so
        /// the guard refuses rather than guessing.
        case unresolvable(String)
    }

    /// `main`, `main:0`, `main:0.1`, `=main`, `$0`, `%3`, `:1` — pull out the session.
    static func sessionReference(_ raw: String) -> SessionReference {
        var value = raw
        if value.hasPrefix("=") { value = String(value.dropFirst()) }
        if value.isEmpty { return .current }
        if let colon = value.firstIndex(of: ":") {
            let head = String(value[value.startIndex..<colon])
            if head.isEmpty { return .current }
            value = head
        }
        guard !value.hasPrefix("$"), !value.hasPrefix("%"), !value.hasPrefix("@") else {
            return .unresolvable(raw)
        }
        let legal = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
        guard value.allSatisfy({ legal.contains($0) }) else { return .unresolvable(raw) }
        // A bare index is a window/pane reference in the current session for some
        // commands and a session name for others; refuse rather than pick.
        guard !value.allSatisfy({ $0.isNumber }) else { return .unresolvable(raw) }
        return .named(value)
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
            // site uses, and a `connectCommand` written `TMUX new-session -A -s fin` (legal
            // on this case-insensitive volume) otherwise yielded ownSession == nil, which
            // silently disarms the fail-closed fallback the whole design leans on.
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
    /// (`$(…)`, backticks) is treated as a boundary, so `$(tmux send-keys …)` is parsed
    /// as its own segment rather than swallowed into a word.
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
                    // `mux kill-session -t main` becomes one word `tmux` in one send.
                    // Appending the newline instead produced the token `t\nmux`, which is
                    // not tmux to this parser and is tmux to the shell. (CRLF is a single
                    // Character in Swift, so it needs its own comparison.)
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
                // `$(`/`${` are already word boundaries below, so only the quote forms
                // need handling here.
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

    /// The cheap prefilter. It must be a SUPERSET of what the lexer can find, so it
    /// cannot just look for the substring: a quote or a backslash anywhere means the
    /// shell may assemble the word out of pieces (`t\mux`, `tm"u"x`), and those forms run.
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

    // MARK: - Half-typed lines

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

    /// `t\` + `mux send-keys -t main …`: neither half contains the word, but the shell
    /// joins them. A trailing fragment alone in command position that is a prefix of
    /// `tmux` is treated as the first half of one.
    static func trailingWordCouldBecomeTmux(_ input: String) -> Bool {
        guard let segment = segments(in: input).last, segment.count == 1, let word = segment.first else {
            return false
        }
        let fragment = normalized(word.text)
        return !fragment.isEmpty && "tmux".hasPrefix(fragment)
    }

    // MARK: - ssh

    /// Hosts that mean "this machine", where a tmux command really does land on the
    /// server this guard is protecting. Anything else is another machine's namespace.
    static let localHostNames: Set<String> = ["localhost", "127.0.0.1", "::1", "0.0.0.0", "0"]

    /// ssh options that take a value, so the word after them is not the destination.
    private static let sshValueFlags: Set<Character> = [
        "b", "c", "D", "E", "e", "F", "I", "i", "J", "L", "l", "m", "O", "o",
        "p", "Q", "R", "S", "W", "w",
    ]

    static func sshRunsOnThisMachine(_ args: [Word], localAliases: Set<String> = []) -> Bool {
        var index = 0
        while index < args.count {
            let token = args[index].text
            guard token.hasPrefix("-"), token.count > 1 else { break }
            let letters = Array(token.dropFirst())
            // getopt again: a value flag at the END of a cluster takes the next argument.
            // The old `letters.count == 1` test meant `ssh -4p 22 localhost tmux
            // kill-session -t main` read `22` as the destination, decided it was a remote
            // machine, and allowed a genuinely local mutation unparsed.
            var consumesNextArgument = false
            for (position, letter) in letters.enumerated() where sshValueFlags.contains(letter) {
                consumesNextArgument = position == letters.count - 1
                break
            }
            index += consumesNextArgument ? 2 : 1
        }
        guard index < args.count else { return false }
        return isLocalDestination(args[index].text, aliases: localAliases)
    }

    /// "Is this ssh destination the machine the guard is defending?" A remote hop is out
    /// of scope by policy, but only because another machine's session names are not in
    /// this registry's namespace — reaching THIS host under another of its own names is
    /// the same namespace by a different road, and used to be classified remote and
    /// allowed unparsed (`ssh Levis-iMac.local tmux send-keys -t main …`).
    static func isLocalDestination(_ raw: String, aliases: Set<String>) -> Bool {
        var host = normalized(raw)
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while host.hasSuffix(".") { host.removeLast() }       // a rooted FQDN
        if host.hasPrefix("::ffff:") { host = String(host.dropFirst(7)) }  // v4-mapped v6
        if let percent = host.firstIndex(of: "%") { host = String(host[..<percent]) } // scope id
        if localHostNames.contains(host) { return true }
        if host.hasPrefix("127.") { return true }             // the whole 127/8 block
        return aliases.contains(host)
    }

    /// Every name this machine answers to, collected ONCE at launch (`TmuxSendGuard
    /// .forHost`): hostname long and short, the `.local` form, and every address its
    /// interfaces carry. Impure by necessity — the pure matcher above takes the result —
    /// and cheap, because it runs once per daemon launch, never per send.
    ///
    /// An ssh config `Host` alias that points here is NOT resolvable from this side and
    /// stays in the residual list.
    static func thisMachineNames() -> Set<String> {
        var names: Set<String> = []
        func addHostName(_ raw: String) {
            let value = normalized(raw).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            guard !value.isEmpty else { return }
            names.insert(value)
            if let dot = value.firstIndex(of: "."), !value.hasPrefix("[") {
                let short = String(value[..<dot])
                guard !short.isEmpty, !short.allSatisfy({ $0.isNumber }) else { return }
                names.insert(short)
                names.insert(short + ".local")
            }
        }
        func addAddress(_ raw: String) {
            // No short-name splitting: `192.168.1.5` must not contribute `192`.
            let value = normalized(raw).trimmingCharacters(in: CharacterSet(charactersIn: " "))
            if !value.isEmpty { names.insert(value) }
        }

        addHostName(ProcessInfo.processInfo.hostName)
        for address in machineInterfaceAddresses() { addAddress(address) }
        return names
    }

    /// The addresses this host's interfaces answer on, numeric, loopback and link-local
    /// included. `ssh 192.168.1.42 tmux kill-session -t main` lands on this very tmux
    /// server; without this it read as "another machine" and was allowed unparsed.
    static func machineInterfaceAddresses() -> [String] {
        var addresses: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return addresses }
        defer { freeifaddrs(head) }
        var cursor = head
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let raw = current.pointee.ifa_addr else { continue }
            let family = raw.pointee.sa_family
            let length: socklen_t
            if family == sa_family_t(AF_INET) {
                length = socklen_t(MemoryLayout<sockaddr_in>.size)
            } else if family == sa_family_t(AF_INET6) {
                length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            } else {
                continue
            }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                raw, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST
            )
            guard status == 0 else { continue }
            addresses.append(String(cString: buffer))
        }
        return addresses
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
