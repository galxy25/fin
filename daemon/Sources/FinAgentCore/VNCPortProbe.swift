// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
import Foundation

/// Is a VNC/RFB server actually accepting on this machine right now?
///
/// A plain loopback connect-and-close against 127.0.0.1:5900 — deliberately NOT a read
/// of macOS's service state (`launchctl print system/com.apple.screensharing` and
/// friends). Two reasons, and the second is the load-bearing one:
///
/// 1. It mirrors the control plane's own `_relay_is_accepting` reasoning (lambda.py):
///    an EC2 instance that has begun terminating reads "running" for the ~1 minute it
///    takes to actually die, so the relay TCP-probes the port instead of trusting the
///    state a control API reports. The same is true here — Screen Sharing toggled off
///    in System Settings, or blocked by an MDM profile, can leave stale service state
///    behind. The socket is the only thing that can't lie about whether a session would
///    actually connect.
/// 2. It needs no privilege. `launchctl load`/`unload` on com.apple.screensharing's
///    LaunchDaemon wants root; `connect()` to a loopback port wants nothing. fin-agentd
///    runs unprivileged today by the same deliberate choice that produced the "no sshd,
///    BY DESIGN" posture on the work laptop, and VNC support must not be the reason that
///    changes — this DETECTS an already-running Screen Sharing server, it never gains
///    the ability to turn one on.
public enum VNCPortProbe {
    /// macOS Screen Sharing's RFB port. Fixed and well-known; there is no per-machine
    /// configuration of it worth carrying, and a site serving RFB somewhere else is not
    /// a case this feature claims to support.
    public static let port: UInt16 = 5900

    /// How long a loopback connect may take before it counts as closed. Generous for a
    /// same-machine socket (which either answers immediately or refuses immediately)
    /// and short enough that a pathological hang can never delay a heartbeat — this runs
    /// on the capabilities path, which must never be the reason a beat is late.
    public static let timeout: TimeInterval = 0.5

    /// True when something is listening. Any failure — refused, timed out, sandboxed,
    /// unreachable — reads as false: "not reachable" and "not there" are the same answer
    /// to the only question the capability asks, and a probe that threw would just make
    /// the heartbeat's error path carry a question it can't answer either.
    public static func isReachable(
        host: String = "127.0.0.1", port: UInt16 = VNCPortProbe.port, timeout: TimeInterval = VNCPortProbe.timeout
    ) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var timeval = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeval, socklen_t(MemoryLayout<Foundation.timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeval, socklen_t(MemoryLayout<Foundation.timeval>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else { return false }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }
}
