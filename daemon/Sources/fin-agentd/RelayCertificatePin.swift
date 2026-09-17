import Foundation
import Crypto
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The daemon's copy of the app's `fin/Session/RelayCertificatePin.swift` —
/// same pin, same reasoning, kept separately because the app target and this
/// executable share no module. See that file for why the terminal relay is
/// pinned rather than name-checked (short version: it is an on-demand body
/// with a new public IP every launch and no stable hostname, and renting one —
/// an Elastic IP's idle charge, or a load balancer's monthly floor — would
/// cost more, standing, than the instance it fronts).
///
/// KEEP IN SYNC with the app's copy and with what
/// `scripts/cloud-agent/control-plane/deploy.sh` prints as
/// "Relay certificate pin (SHA-256 of DER)".
enum RelayCertificatePin {
    static let sha256 = "6886b52b6494b30696a2b27a27b4f5ca11e0de160d8e1887f4cae84aa37e230d"

    static func matches(_ certificate: SecCertificate) -> Bool {
        let der = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        return digest == sha256
    }
}

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
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
