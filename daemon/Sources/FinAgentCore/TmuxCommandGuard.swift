// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation

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
// background job, `ssh host` to a machine we can't reason about). The structural fix is
// a dedicated socket (`tmux -L fin new-session -A -s fin`), which removes the human's
// sessions from the agent's namespace entirely at the cost of being able to READ them.
// See daemon/README.md § "The tmux send-keys guard" for the full residual list.
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
    /// Snapshot of the registry's session names, used when no file URL is set.
    public var registrySessions: Set<String>
    public var hasRegistry: Bool
    /// Re-read on every evaluation when set, so a session the model registers mid-run
    /// becomes writable without a daemon restart — and so a registry that is DELETED
    /// mid-run shrinks the allow-list back to the agent's own session.
    public var registryFileURL: URL?

    public init(
        isEnforced: Bool,
        ownSession: String?,
        ownSocket: TmuxSocket = .standard,
        registrySessions: Set<String> = [],
        hasRegistry: Bool = false,
        registryFileURL: URL? = nil
    ) {
        self.isEnforced = isEnforced
        self.ownSession = ownSession
        self.ownSocket = ownSocket
        self.registrySessions = registrySessions
        self.hasRegistry = hasRegistry
        self.registryFileURL = registryFileURL
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
            registryFileURL: registryFileURL
        )
    }

    /// The live allow-list: the agent's own session plus every registered session.
    /// When a file URL is set it is the authority — a missing or unreadable file means
    /// an EMPTY registry, not a retained snapshot, so deleting the file cannot widen it.
    public func resolved() -> (allowed: Set<String>, hasRegistry: Bool) {
        var sessions = registrySessions
        var present = hasRegistry
        if let registryFileURL {
            if let document = RegistryDocument.loadIfPresent(at: registryFileURL) {
                sessions = Set(document.sessions.map(\.session))
                present = true
            } else {
                sessions = []
                present = false
            }
        }
        if let ownSession { sessions.insert(ownSession) }
        return (sessions, present)
    }

    public func evaluate(_ input: String) -> TmuxGuardVerdict {
        guard isEnforced else { return .allow }
        let (allowed, present) = resolved()
        return TmuxCommandGuard.evaluate(
            input,
            allowedSessions: allowed,
            ownSession: ownSession,
            ownSocket: ownSocket,
            hasRegistry: present
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
/// Dependency-free and side-effect-free (the one exception, registry re-reads, lives in
/// `TmuxSendGuard`), so the whole policy table is unit-testable as strings.
public enum TmuxCommandGuard {

    // MARK: - Public API

    public static func evaluate(
        _ input: String,
        allowedSessions: Set<String>,
        ownSession: String?,
        ownSocket: TmuxSocket = .standard,
        hasRegistry: Bool = true
    ) -> TmuxGuardVerdict {
        // Fast path AND blast-radius bound: a command that never mentions tmux (or a
        // process-killer aimed at it) is not this guard's business, and must behave
        // byte-for-byte as it did before. Everything else pays the parser.
        guard input.contains("tmux") else { return .allow }
        let context = Context(
            allowed: allowedSessions,
            ownSession: ownSession,
            ownSocket: ownSocket,
            hasRegistry: hasRegistry
        )
        return evaluate(line: input, depth: 0, context: context)
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
            registered. \(scope)

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
    /// re-scanned for a tmux invocation (`ssh box tmux …`, `xargs tmux …`).
    static let commandCarriers: Set<String> = [
        "ssh", "eval", "xargs", "watch", "timeout", "script", "flock",
        "sh", "bash", "zsh", "dash", "fish", "ksh",
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
    }

    // MARK: - Evaluation

    static func evaluate(line: String, depth: Int, context: Context) -> TmuxGuardVerdict {
        for segment in segments(in: line) {
            let verdict = evaluate(segment: segment, depth: depth, context: context)
            if verdict.isRefusal { return verdict }
        }
        return .allow
    }

    private static func evaluate(segment words: [Word], depth: Int, context: Context) -> TmuxGuardVerdict {
        guard !words.isEmpty else { return .allow }

        // A quoted argument is its own little command line: `sh -c 'tmux …'`,
        // `eval "tmux …"`, and the two-hop `tmux send-keys -t fin 'tmux … -t main'`
        // all land here. Only quoted words that actually mention tmux pay the recursion.
        for word in words where word.wasQuoted && word.text.contains("tmux") {
            guard depth < maxNestingDepth else {
                return refusal(
                    "that command nests tmux inside quoted shell text more deeply than Fin's guard "
                        + "will unwrap, so it cannot be proven read-only.",
                    session: nil,
                    context: context
                )
            }
            let verdict = evaluate(line: word.text, depth: depth + 1, context: context)
            if verdict.isRefusal { return verdict }
        }

        // Strip `sudo`/`env FOO=1`/`exec`… to find the real head.
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
            if benignPrefixes.contains(basename(token)) {
                index += 1
                strippedPrefix = true
                continue
            }
            break
        }
        guard index < words.count else { return .allow }

        let head = basename(words[index].text)
        let tail = Array(words[(index + 1)...])

        if head == "tmux" {
            return evaluate(invocation: tail, depth: depth, context: context)
        }

        if processKillers.contains(head), tail.contains(where: { $0.text.contains("tmux") }) {
            return refusal(
                "`\(head)` aimed at tmux would kill the tmux server and every session on it, "
                    + "including sessions that are not Fin's.",
                session: nil,
                context: context
            )
        }

        // `ssh box tmux …`, `xargs tmux …`, `sudo -u someone tmux …`: the command word
        // is at an offset we can't compute, so scan for it.
        if commandCarriers.contains(head) || strippedPrefix {
            if let hit = tail.firstIndex(where: { basename($0.text) == "tmux" }) {
                return evaluate(invocation: Array(tail[(hit + 1)...]), depth: depth, context: context)
            }
        }

        return .allow
    }

    /// One `tmux …` invocation: global flags, then one or more `;`-separated commands.
    private static func evaluate(invocation args: [Word], depth: Int, context: Context) -> TmuxGuardVerdict {
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
                depth: depth,
                context: context
            )
            if verdict.isRefusal { return verdict }
        }
        return .allow
    }

    private static func evaluate(
        command words: [Word],
        socket: TmuxSocket?,
        socketMismatch: Bool,
        depth: Int,
        context: Context
    ) -> TmuxGuardVerdict {
        // Bare `tmux` (or a trailing `;`): new-session with a generated name. It touches
        // nothing that already exists.
        guard let verb = words.first?.text else { return .allow }
        let arguments = Array(words.dropFirst())

        let resolution = resolve(verb)
        guard let command = resolution.command else {
            return refusal(
                "Fin's guard does not recognize the tmux command `\(verb)`, so it cannot prove the "
                    + "command only reads. Unrecognized tmux commands are refused, not guessed at.",
                session: nil,
                context: context
            )
        }

        // Inspection first: reading is allowed on any session and any server.
        if case .readOnly = command.kind { return .allow }
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
            let targets = flagValues("t", in: arguments) + flagValues("s", in: arguments)
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
            guard context.allowed.contains(own) else {
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
                guard let own = context.ownSession, context.allowed.contains(own) else {
                    return refusal(
                        "`\(command)` targets the current session, which Fin cannot resolve to an "
                            + "allowed session name on this host.",
                        session: context.ownSession,
                        context: context
                    )
                }
            case .named(let name):
                guard context.allowed.contains(name) else {
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
        if let session {
            parts.append(
                "If the user wants Fin to drive \"\(session)\", it has to be registered in "
                    + "routing-registry.json first — tell them that, and offer to read the session "
                    + "instead."
            )
        }
        return .refuse(parts.joined(separator: " "))
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
    static func resolve(_ verb: String) -> Resolution {
        guard !verb.isEmpty else { return Resolution(command: nil, ambiguous: false) }
        if let exact = commands.first(where: { $0.name == verb || $0.aliases.contains(verb) }) {
            return Resolution(command: exact, ambiguous: false)
        }
        let matches = commands.filter { $0.name.hasPrefix(verb) }
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
    }

    static func parseGlobalFlags(_ args: [Word]) -> ParsedInvocation {
        var socket: TmuxSocket?
        var index = 0
        while index < args.count {
            let token = args[index].text
            guard token.hasPrefix("-"), token.count > 1 else { break }
            let letters = Array(token.dropFirst())
            let key = letters[0]
            let attached = String(letters.dropFirst())
            switch key {
            case "L", "S", "f", "c", "T":
                var value = attached
                if value.isEmpty {
                    index += 1
                    value = index < args.count ? args[index].text : ""
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
                    return ParsedInvocation(
                        socket: socket, arguments: [],
                        refusal: "`tmux -f` loads an alternate config file, which can bind keys that execute commands."
                    )
                default: break
                }
            default:
                break
            }
            index += 1
        }
        return ParsedInvocation(socket: socket, arguments: Array(args[index...]), refusal: nil)
    }

    /// tmux's own multi-command form: `tmux a \; b`. The shell hands us `;` as a plain
    /// word (from `\;`, `';'` or `";"`), so an UNQUOTED word that is or ends with `;`
    /// starts a new tmux command. A quoted `;` inside a send-keys payload does not.
    static func subcommands(of args: [Word]) -> [[Word]] {
        var result: [[Word]] = []
        var current: [Word] = []
        for word in args {
            if !word.wasQuoted, word.text == ";" {
                result.append(current)
                current = []
                continue
            }
            if !word.wasQuoted, word.text.hasSuffix(";"), word.text.count > 1 {
                current.append(Word(text: String(word.text.dropLast()), wasQuoted: false))
                result.append(current)
                current = []
                continue
            }
            current.append(word)
        }
        result.append(current)
        return result.filter { !$0.isEmpty }
    }

    /// Every value given to `-<flag>`, in both the separated (`-t main`) and attached
    /// (`-tmain`) forms. ALL of them are checked: a literal argument that merely looks
    /// like `-t` costs a false refusal, which is the safe direction.
    static func flagValues(_ flag: Character, in args: [Word]) -> [String] {
        var values: [String] = []
        var index = 0
        while index < args.count {
            let token = args[index].text
            if token.hasPrefix("-"), !token.hasPrefix("--"), token.count > 1, !args[index].wasQuoted {
                let letters = Array(token.dropFirst())
                if letters[0] == flag {
                    let attached = String(letters.dropFirst())
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

    static func hasFlag(_ letter: Character, in args: [Word]) -> Bool {
        args.contains { word in
            guard !word.wasQuoted, word.text.hasPrefix("-"), !word.text.hasPrefix("--") else { return false }
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
            guard let hit = segment.firstIndex(where: { basename($0.text) == "tmux" }) else { continue }
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
                    current.append(characters[index])
                    started = true
                    index += 1
                }
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
