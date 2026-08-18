import Foundation
import SwiftData

@Model
final class Server {
    var id: UUID = UUID()
    var name: String = ""
    var host: String = ""
    var port: Int = 22
    var username: String = ""
    var keyID: UUID?
    var tmuxSessionName: String = "main"
    /// Sent verbatim (as if typed) right after the shell connects. Empty means
    /// send nothing — for hosts (like one set up with a shell-profile tmux/mosh
    /// auto-attach) where anything we type would just be redundant input to erase.
    var connectCommand: String = ""
    var createdAt: Date = Date()

    init(
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        keyID: UUID? = nil,
        tmuxSessionName: String = "main",
        connectCommand: String = ""
    ) {
        self.id = UUID()
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.keyID = keyID
        self.tmuxSessionName = tmuxSessionName
        self.connectCommand = connectCommand
        self.createdAt = Date()
    }
}
