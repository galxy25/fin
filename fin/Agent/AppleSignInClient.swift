import Foundation

/// Exchanges a Sign in with Apple identity token for the control plane's own
/// per-user session token (`POST /auth/apple` — see `scripts/cloud-agent/
/// control-plane/lambda.py`'s `auth_apple`/`_verify_apple_identity_token`).
/// This is the ONLY control-plane call that needs no prior bearer token —
/// it's how one is obtained — so it takes the endpoint explicitly rather than
/// going through `CloudControlPlaneConfig`: the tvOS target compiles this file
/// without the rest of `fin/Agent` and reads the endpoint straight from iCloud
/// Key-Value Storage (`TVCloudAccount`).
enum AppleSignInClient {
    enum Outcome: Equatable {
        case signedIn(sessionToken: String)
        case notConfigured
        case failed(String)
    }

    /// `identityToken` is the raw bytes from `ASAuthorizationAppleIDCredential
    /// .identityToken`, UTF-8 decoded by the caller (`AppleSignInButton`) —
    /// kept as `String` here so this stays testable without AuthenticationServices.
    static func signIn(identityToken: String, endpoint: String) async -> Outcome {
        var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, let url = URL(string: base + "/auth/apple") else {
            return .notConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["identityToken": identityToken])
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return outcome(status: nil, body: nil)
        }
        return outcome(status: (response as? HTTPURLResponse)?.statusCode, body: data)
    }

    /// Pure so every branch is testable without a server. Never logs or
    /// surfaces the identity token itself — only the resulting session token
    /// (still a credential, but the app already treats `CloudControlPlaneConfig
    /// .token` this way) or a server error string.
    static func outcome(status: Int?, body: Data?) -> Outcome {
        guard let status else { return .failed("network error") }
        let fields = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        guard status == 200 else {
            let message = (fields?["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .failed(message ?? "HTTP \(status)")
        }
        guard let token = fields?["token"] as? String, !token.isEmpty else {
            return .failed("control plane did not return a session token")
        }
        return .signedIn(sessionToken: token)
    }
}
