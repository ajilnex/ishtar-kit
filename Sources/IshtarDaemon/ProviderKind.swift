import Foundation

/// Les familles de fournisseurs que le démon sait joindre.
///
/// `LLMClient` est la couture : la session outillée, les outils et l'interface ne
/// connaissent que ce contrat. Y brancher MLX (invariant n° 5, jalon M3) n'oblige
/// donc à toucher ni la boucle, ni la vérification des citations, ni les vues.
public enum ProviderKind: Sendable, CaseIterable {
    /// API Messages native d'Anthropic.
    case anthropic
    /// Dialecte « chat completions » : OpenAI, Gemini, Mistral, OpenRouter, et
    /// les serveurs locaux (Ollama, LM Studio, llama.cpp, vLLM).
    case openAICompatible
    /// Modèle chargé dans le processus via MLX Swift. La fabrique rend `nil`
    /// tant qu'aucun client ne sert cette famille.
    case localMLX

    /// Déduit la famille de l'adresse. Aucun réseau.
    public static func inferred(from baseURL: URL) -> ProviderKind {
        baseURL.host?.lowercased().contains("anthropic") == true
            ? .anthropic : .openAICompatible
    }

    /// Vrai quand le fournisseur tourne sur la machine de l'utilisateur : rien
    /// ne sort, et aucune clé n'est exigée.
    public static func isLocal(_ baseURL: URL) -> Bool {
        guard let host = baseURL.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(host)
            || host.hasSuffix(".local")
    }
}

/// Fabrique le client d'une configuration. `nil` signale une famille que le
/// moteur ne sert pas encore (MLX).
public enum LLMClientFactory {
    public static func make(config: LLMProviderConfig,
                            session: URLSession = .shared) -> (any LLMClient)? {
        switch ProviderKind.inferred(from: config.baseURL) {
        case .anthropic:
            return AnthropicClient(config: config, session: session)
        case .openAICompatible:
            return OpenAICompatibleClient(config: config, session: session)
        case .localMLX:
            return nil
        }
    }
}
