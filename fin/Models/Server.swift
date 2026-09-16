import Foundation
import SwiftData

/// How this server is reached. `.direct` is the original Citadel/SSH path
/// (host/port/username/key all meaningful); `.siteRelay` has no dialable
/// address at all — it names a Fin site (a resident daemon that can only
/// call out) and asks the control plane to relay a PTY session through that
/// site's own outbound channel instead. New raw values are additive only:
/// an unknown value never appears since this is decoded from our own store.
enum ServerTransport: String, Codable {
    case direct
    case siteRelay
}

@Model
final class Server {
    var id: UUID = UUID()
    var name: String = ""
    var host: String = ""
    var port: Int = 22
    var username: String = ""
    var keyID: UUID?
    /// Backing storage for `transport`, kept as a plain optional String rather
    /// than the enum itself: a CloudKit-synced row created before this field
    /// existed has no value for it at all, and SwiftData's synthesized
    /// accessor for a non-optional Codable enum force-casts that absence,
    /// crashing every time the row is read (`swift_dynamicCastFailure` in
    /// `ServerListView.row(for:)`, 2026-09-16 TestFlight crash). An optional
    /// String column has no such accessor — it is simply nil — so decoding it
    /// ourselves in `transport`'s getter can fall back to `.direct` instead of
    /// trapping.
    var transportRaw: String?
    /// Only meaningful for `.direct`; a `.siteRelay` server has no address of
    /// its own — see `relaySiteId`. Absent/unrecognized `transportRaw` reads as
    /// `.direct`, matching every row that predates this field.
    var transport: ServerTransport {
        get { transportRaw.flatMap(ServerTransport.init(rawValue:)) ?? .direct }
        set { transportRaw = newValue.rawValue }
    }
    /// The Fin site (`FinSite.siteId`) to relay through, when `transport ==
    /// .siteRelay`. nil for `.direct` and for a `.siteRelay` row that hasn't
    /// had a site picked yet.
    var relaySiteId: String?
    var tmuxSessionName: String = "main"
    /// Sent verbatim (as if typed) right after the shell connects. Empty means
    /// send nothing — for hosts (like one set up with a shell-profile tmux/mosh
    /// auto-attach) where anything we type would just be redundant input to erase.
    var connectCommand: String = ""
    /// Keeps the device screen from idle-locking while this server's session is on
    /// screen (iOS/iPadOS; the Mac manages its own display sleep). Off by default —
    /// burning the battery of everyone who didn't ask is worse than one person relocking.
    var keepScreenAwake: Bool = false
    var createdAt: Date = Date()

    init(
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        keyID: UUID? = nil,
        transport: ServerTransport = .direct,
        relaySiteId: String? = nil,
        tmuxSessionName: String = "main",
        connectCommand: String = "",
        keepScreenAwake: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.keyID = keyID
        self.transport = transport
        self.relaySiteId = relaySiteId
        self.tmuxSessionName = tmuxSessionName
        self.connectCommand = connectCommand
        self.keepScreenAwake = keepScreenAwake
        self.createdAt = Date()
    }
}
