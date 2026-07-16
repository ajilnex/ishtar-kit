import Foundation

// Le contrat client LLM du démon. Un seul dialecte couvre l'essentiel du monde :
// l'API « chat completions » OpenAI-compatible (OpenAI, Mistral, OpenRouter,
// Groq, DeepSeek… et surtout les serveurs LOCAUX Ollama et LM Studio — le
// « modèle hébergé localement » sans embarquer aucun runtime). Anthropic natif
// viendra comme second client. BYOK : la clé appartient à l'utilisateur.

public struct LLMMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case system, user, assistant, tool }
    public var role: Role
    public var content: String
    /// Appels d'outils portés par un message assistant.
    public var toolCalls: [LLMToolCall]
    /// Identifiant d'appel auquel répond un message `tool`.
    public var toolCallID: String?

    public init(role: Role, content: String,
                toolCalls: [LLMToolCall] = [], toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

public struct LLMToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    /// Arguments, JSON brut tel que produit par le modèle.
    public var argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// Déclaration d'un outil (schéma JSON des paramètres, format OpenAI).
public struct LLMToolSpec: Sendable {
    public var name: String
    public var description: String
    /// Schéma JSON des paramètres, déjà sérialisé.
    public var parametersJSON: String

    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

/// Fragments du flux de réponse.
public enum LLMChunk: Sendable {
    /// Du texte assistant, au fil de l'eau.
    case text(String)
    /// Fin du tour : les appels d'outils complets (vide = réponse finale).
    case finished(toolCalls: [LLMToolCall])
}

public protocol LLMClient: Sendable {
    func stream(messages: [LLMMessage], tools: [LLMToolSpec])
        -> AsyncThrowingStream<LLMChunk, Error>
}

/// Configuration d'un fournisseur OpenAI-compatible.
public struct LLMProviderConfig: Sendable, Equatable {
    /// Base de l'API, ex. `https://api.openai.com/v1`,
    /// `https://api.mistral.ai/v1`, `http://localhost:11434/v1` (Ollama).
    public var baseURL: URL
    /// Clé API (nil pour un serveur local sans authentification).
    public var apiKey: String?
    public var model: String

    public init(baseURL: URL, apiKey: String?, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }
}
