import Foundation

/// App-side bridge to the shared transcript export in FinAgentCore.
///
/// `AgentTranscript.markdownExport(context:)` moved to `daemon/Sources/FinAgentCore/`
/// (shared with the headless daemon) and takes a plain `ExportContext` there; this
/// keeps the app's ergonomic `Agent`-model signature by building that context from the
/// SwiftData model plus the app bundle's version — both of which only exist app-side.
extension AgentTranscript {
    func markdownExport(agent: Agent, serverName: String) -> String {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        var context = ExportContext(
            agentName: agent.name,
            serverName: serverName,
            producedBy: "Fin \(appVersion) (\(buildNumber))",
            providerLabel: agent.provider.rawValue,
            contextWindowTokens: agent.contextWindowTokens,
            maxOutputTokens: agent.maxOutputTokens,
            temperature: agent.temperature,
            terminalContextLines: agent.terminalContextLines
        )
        if agent.provider == .openAICompatible {
            context.endpointURL = agent.endpointURL
            context.modelIdentifier = agent.modelIdentifier
        }
        return markdownExport(context: context)
    }
}
