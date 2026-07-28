import Foundation

/// Les modèles offerts par un point d'entrée OpenAI-compatible. L'analyse est
/// PURE et testée sans réseau ; seule `fetch` sort de la machine.
///
/// Sert surtout aux serveurs locaux : le chercheur ne devine plus l'identifiant
/// exact du modèle qu'il a chargé, il le choisit dans une liste.
public enum ModelListing {
    /// Tolère les deux formes rencontrées : `{"data":[{"id":…}]}` (OpenAI,
    /// LM Studio, Ollama sur `/v1`) et `{"models":[{"name":…}]}` (API native
    /// d'Ollama, quand l'utilisateur pointe la racine du serveur).
    public static func parse(_ data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any] else { return [] }
        if let entries = object["data"] as? [[String: Any]] {
            return entries.compactMap { $0["id"] as? String }.sorted()
        }
        if let entries = object["models"] as? [[String: Any]] {
            return entries.compactMap { $0["name"] as? String ?? $0["id"] as? String }
                .sorted()
        }
        return []
    }

    /// Interroge `GET {base}/models`. Les serveurs locaux n'exigent pas de clé.
    public static func fetch(baseURL: URL, apiKey: String?,
                             session: URLSession = .shared) async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        if let key = apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
            throw DaemonError.provider(
                status: http.statusCode,
                body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return parse(data)
    }
}

/// Ce qu'un modèle sait faire de l'outillage du démon.
///
/// Tout le démon repose sur l'appel d'outils : fouiller la bibliothèque, compter,
/// ouvrir le lecteur à la bonne page. Un modèle qui n'en est pas capable répond
/// de mémoire, sans citation — or l'invariant n° 6 interdit d'afficher une sortie
/// non validée. Le dire d'emblée vaut mieux que de laisser le chercheur croire
/// que sa bibliothèque est mal indexée.
public enum ToolSupport: Sendable, Equatable {
    case supported
    case unsupported
    /// L'épreuve n'a pas abouti : serveur éteint, clé refusée, réseau.
    case undetermined(String)
}

public enum CapabilityProbe {
    /// Un tour, sans bibliothèque : on demande au modèle d'appeler un outil
    /// trivial. S'il répond en prose, il ne sait pas outiller.
    public static func toolSupport(of client: any LLMClient) async -> ToolSupport {
        let probe = LLMToolSpec(
            name: "ishtar_probe",
            description: "Test de disponibilité. Appelle-le sans rien demander d'autre.",
            parametersJSON: #"{"type":"object","properties":{}}"#)
        let messages = [LLMMessage(
            role: .user,
            content: "Appelle l'outil ishtar_probe. N'écris rien d'autre.")]
        do {
            for try await chunk in client.stream(messages: messages, tools: [probe]) {
                if case let .finished(calls) = chunk {
                    return calls.isEmpty ? .unsupported : .supported
                }
            }
            return .unsupported
        } catch {
            return .undetermined(error.localizedDescription)
        }
    }
}
