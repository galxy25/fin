import Foundation
import Network

/// The app's WebSocket to the terminal relay, on Network.framework rather than
/// `URLSessionWebSocketTask`.
///
/// WHY NOT URLSession: App Transport Security refuses the relay's self-signed
/// certificate, and a `URLSessionDelegate` server-trust override does not
/// rescue it — ATS fails the connection before the app's own judgement gets a
/// say. That was proven by running one binary two ways: as a bare command-line
/// tool it connects to the live relay and exchanges frames; inside an `.app`
/// bundle, where ATS applies, the identical code fails with
/// `NSURLErrorDomain Code=-1200` (2026-09-17) — which is exactly what the phone
/// reported. ATS governs URLSession and WebKit; it does not govern
/// Network.framework, so moving this ONE socket here is what lets the app keep
/// a pinned self-signed certificate instead of renting a hostname (see
/// `RelayCertificatePin` for that cost argument).
///
/// The framing is `NWProtocolWebSocket`'s, not ours: RFC 6455 is a solved
/// problem and hand-rolling masking and continuation frames to save a
/// dependency on the OS's own implementation would be a poor trade.
///
/// Deliberately NOT `@MainActor`, unlike its only caller: this is a transport,
/// its callbacks arrive on its own queue, and the continuation bookkeeping
/// below is what makes it safe to await from the main actor.
final class RelayWebSocket: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case connect(String)
        case send(String)
        case receive(String)
        /// The peer closed the socket. Distinct from a transport error because
        /// the caller's receive loop ends the session either way, but only one
        /// of the two is worth reporting as a fault.
        case closed

        var description: String {
            switch self {
            case .connect(let detail): return "relay connect failed: \(detail)"
            case .send(let detail): return "relay send failed: \(detail)"
            case .receive(let detail): return "relay receive failed: \(detail)"
            case .closed: return "relay closed the connection"
            }
        }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.levischoen.fin.relay-websocket")
    /// SEPARATE from `queue`, not sloppiness: the verify block runs as part of
    /// the handshake that `queue` is driving, so handing it that same serial
    /// queue invites the connection to wait on itself.
    private static let verifyQueue = DispatchQueue(label: "dev.levischoen.fin.relay-websocket.verify")
    /// Guards the two pieces of mutable state below, which are touched from
    /// both the caller's task and Network.framework's own queue.
    private let lock = NSLock()
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var isFinished = false

    init(host: String, port: Int) {
        let tls = NWProtocolTLS.Options()
        // REPLACES the default evaluation rather than adding to it — the relay
        // has no name worth checking (a raw IP that changes every launch), so
        // "is this exactly the certificate we shipped a pin for" is both the
        // only question available and a stricter one than the usual chain
        // check: no public CA mis-issuance can satisfy it.
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                      let leaf = chain.first
                else {
                    complete(false)
                    return
                }
                complete(RelayCertificatePin.matches(leaf))
            },
            Self.verifyQueue
        )

        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true

        let parameters = NWParameters(tls: tls)
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)

        // A `.url` endpoint, not `host:port`. The WebSocket upgrade is an HTTP
        // request, and only the URL form gives `NWProtocolWebSocket` a target
        // and Host header to build one from: with a bare host/port, TLS
        // completes, the client then sends NOTHING, and the connection dies as
        // ECONNABORTED — which reads like a rejected certificate and is not
        // one. The relay's own log named it ("connection closed while reading
        // HTTP request line"), which is the only reason this was quick to find.
        let url = URL(string: "wss://\(host):\(port)/") ?? URL(string: "wss://127.0.0.1/")!
        connection = NWConnection(to: .url(url), using: parameters)
    }

    /// Resolves once the socket is usable, or throws. Every exit path resumes
    /// exactly once: `takeConnectContinuation` hands the continuation out at
    /// most one time, so a `.failed` arriving after a `.ready` — or the
    /// deadline racing either — cannot double-resume.
    ///
    /// `.waiting` IS NOT AN ERROR HERE, and treating it as one is what broke
    /// the first real connection from a phone: it failed every attempt with
    /// `ENETDOWN "Network is down"` (2026-09-17). `.waiting` means
    /// Network.framework cannot connect *yet* and will retry itself when
    /// conditions change — on a phone that is the ordinary state while a path
    /// is being brought up, and it usually becomes `.ready` a moment later. A
    /// wired Mac goes straight to `.ready` and never shows it, which is
    /// exactly why a local test could not see this.
    ///
    /// So waiting is allowed to wait, and a DEADLINE is what stops it being
    /// unbounded — the caller's dial loop still owns retrying, it just gets
    /// told after `timeout` instead of on the first hiccup.
    func connect(timeout: TimeInterval = 8) async throws {
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.failConnect(Failure.connect("no relay answered within \(Int(timeout))s"))
        }
        defer { deadline.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            connectContinuation = continuation
            lock.unlock()

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.takeConnectContinuation()?.resume()
                case .failed(let error):
                    self.takeConnectContinuation()?.resume(throwing: Failure.connect(String(describing: error)))
                case .cancelled:
                    self.takeConnectContinuation()?.resume(throwing: Failure.closed)
                default:
                    // Including `.waiting` — see the note above.
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Ends a connect attempt from outside the state handler (the deadline),
    /// tearing down the connection so a superseded attempt cannot later
    /// become ready behind the caller's back.
    private func failConnect(_ failure: Failure) {
        guard let continuation = takeConnectContinuation() else { return }
        connection.cancel()
        continuation.resume(throwing: failure)
    }

    private func takeConnectContinuation() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = connectContinuation
        connectContinuation = nil
        return continuation
    }

    func send(_ data: Data) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "relay-frame", metadata: [metadata])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: Failure.send(String(describing: error)))
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    /// One WebSocket message. `NWProtocolWebSocket` delivers whole messages, so
    /// there is no reassembly to do here — but a close frame arrives through
    /// the same callback as data, and has to end the loop rather than be fed to
    /// a terminal as if it were output.
    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receiveMessage { content, context, _, error in
                if let error {
                    continuation.resume(throwing: Failure.receive(String(describing: error)))
                    return
                }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                if let websocketMetadata = metadata as? NWProtocolWebSocket.Metadata,
                   websocketMetadata.opcode == .close {
                    continuation.resume(throwing: Failure.closed)
                    return
                }
                guard let content else {
                    // A ping/pong the stack already answered, or an empty
                    // frame: nothing for the caller, and resuming with empty
                    // data would look like a malformed relay frame.
                    continuation.resume(throwing: Failure.closed)
                    return
                }
                continuation.resume(returning: content)
            }
        }
    }

    /// Idempotent, and safe to call from anywhere — including from inside a
    /// frame handler that is itself running off a `receive()`.
    func cancel() {
        lock.lock()
        let alreadyFinished = isFinished
        isFinished = true
        lock.unlock()
        guard !alreadyFinished else { return }
        connection.cancel()
    }
}
