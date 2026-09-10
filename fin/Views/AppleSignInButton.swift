import SwiftUI
import AuthenticationServices

/// "Sign in with Apple" → the control plane's own per-user session token
/// (`AppleSignInClient`), replacing the manual token paste as the PRIMARY way
/// onto a real multi-tenant account. The manual fields in `AgentEditView`
/// stay for the one case that still needs them: copying a session token into
/// a non-interactive process (the daemon) that can't run Sign in with Apple
/// itself — see `scripts/mac-fin-agentd/provision-config.sh`.
struct AppleSignInButton: View {
    @State private var outcome: AppleSignInClient.Outcome?
    @State private var isSigningIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SignInWithAppleButton(.signIn) { request in
                // Identity only — the control plane keys everything off Apple's
                // stable `sub`, never a name or email.
                request.requestedScopes = []
            } onCompletion: { result in
                handle(result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 44)
            .disabled(isSigningIn)

            statusLine
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch outcome {
        case .signedIn:
            Label("Signed in — this device's control-plane token is now yours.",
                  systemImage: "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .notConfigured:
            Label("Set the Control Plane URL below first.", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
        case nil:
            EmptyView()
        }
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            // A user-cancelled sheet surfaces as an ASAuthorizationError with
            // code .canceled — worth staying quiet about rather than flashing
            // an "error" the user didn't cause.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            outcome = .failed(error.localizedDescription)
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                outcome = .failed("Apple did not return an identity token.")
                return
            }
            isSigningIn = true
            Task {
                let signInOutcome = await AppleSignInClient.signIn(identityToken: identityToken)
                await MainActor.run {
                    isSigningIn = false
                    outcome = signInOutcome
                    if case .signedIn(let sessionToken) = signInOutcome {
                        CloudControlPlaneConfig.setToken(sessionToken)
                    }
                }
            }
        }
    }
}
