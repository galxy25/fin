import Foundation
import CryptoKit

/// Trust for the terminal relay, which has no trustworthy name to check.
///
/// The relay is an on-demand EC2 body: it is launched when a terminal is
/// opened and terminates itself when the last one closes, so it has a new
/// public IP every time and no stable hostname at all. A normal CA-issued
/// certificate needs exactly what that lacks — a name — and buying one for a
/// changing address means an Elastic IP (billed while idle, which is most of
/// the time) or a load balancer in front of it (~$16/month floor even at zero
/// traffic). Both cost more, standing, than the instance they would front.
///
/// So the relay presents ONE self-signed certificate, generated once by
/// `control-plane/deploy.sh` and installed on every relay instance, and both
/// clients check it by identity instead of by name: this exact certificate, or
/// no connection. That is a stronger statement than the usual hostname check —
/// a public CA mis-issuing for some name cannot produce a certificate this
/// accepts — and it is why `.useCredential` here is not the trust bypass it
/// would be if the hash were not compared.
///
/// `pin` is the SHA-256 of the certificate's DER, which is what
/// `deploy.sh` prints on every run (`openssl x509 -outform der | shasum
/// -a 256`). Rotating the certificate means changing this constant and
/// shipping a build, which is the tradeoff accepted for not paying rent on a
/// hostname.
enum RelayCertificatePin {
    /// Printed by `scripts/cloud-agent/control-plane/deploy.sh` as
    /// "Relay certificate pin (SHA-256 of DER)".
    static let sha256 = "6886b52b6494b30696a2b27a27b4f5ca11e0de160d8e1887f4cae84aa37e230d"

    static func matches(_ certificate: SecCertificate) -> Bool {
        let der = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        return digest == sha256
    }
}

/// The `URLSessionDelegate` half of the above. Both the app and the daemon use
/// an identical one; there is no shared module between them, so the daemon
/// carries its own copy (`daemon/Sources/fin-agentd/RelayCertificatePin.swift`)
/// — keep the two in sync, and the pin constant in sync with what deploy.sh
/// last printed.
final class RelayPinningDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              RelayCertificatePin.matches(leaf)
        else {
            // Anything else — a different certificate, a missing chain, a
            // challenge that is not server trust — is refused outright. There
            // is no fallback to the system evaluation: the relay's whole
            // identity IS the pin.
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
