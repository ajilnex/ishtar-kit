import Foundation

/// Une conversation avec le démon : la boucle outillée, minimale et bornée.
/// Le modèle reçoit les outils de la bibliothèque ; chaque tour exécute ses
/// appels puis lui rend les résultats, jusqu'à la réponse finale (budget
/// d'itérations strict — rendements décroissants, jamais de boucle infinie).
///
/// La session émet un unique flux `DaemonEvent` (invariant n° 3) ; les commandes
/// d'interface (`open_document`) sont émises, jamais exécutées ici.
public actor DaemonSession {
    private let client: any LLMClient
    private let toolbox: DaemonToolbox
    private var transcript: [LLMMessage]

    /// Tours outillés maximum par question.
    private static let maxIterations = 6

    public init(client: any LLMClient, toolbox: DaemonToolbox,
                systemPrompt: String? = nil) {
        self.client = client
        self.toolbox = toolbox
        transcript = [LLMMessage(role: .system,
                                 content: systemPrompt ?? Self.defaultSystemPrompt)]
    }

    public static let defaultSystemPrompt = """
    Tu es le démon d'Ishtar : le bibliothécaire personnel d'un chercheur en \
    sciences humaines, au sein de sa bibliothèque numérique locale. Tu réponds \
    dans la langue du chercheur, avec sobriété et précision savante.

    Règles :
    1. Pour toute question sur les textes, cherche D'ABORD dans la bibliothèque \
    (search_library) au lieu de répondre de mémoire.
    2. Cite toujours tes sources : titre et page (« Titre », p. N). Ne cite \
    jamais un passage que tu n'as pas lu via les outils.
    3. Quand tu as trouvé le passage pertinent, MONTRE-le : open_document avec \
    la page et quelques mots exacts en surbrillance.
    4. Si la bibliothèque ne contient pas la réponse, dis-le simplement.
    """

    /// Pose une question ; le flux rend les événements jusqu'à `.finished`.
    public func send(_ userText: String) -> AsyncStream<DaemonEvent> {
        AsyncStream { continuation in
            let task = Task { await self.run(userText, continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ userText: String,
                     _ continuation: AsyncStream<DaemonEvent>.Continuation) async {
        transcript.append(LLMMessage(role: .user, content: userText))

        do {
            for _ in 0..<Self.maxIterations {
                var responseText = ""
                var toolCalls: [LLMToolCall] = []

                for try await chunk in client.stream(messages: transcript,
                                                     tools: toolbox.specs) {
                    switch chunk {
                    case .text(let text):
                        responseText += text
                        continuation.yield(.token(text))
                    case .finished(let calls):
                        toolCalls = calls
                    }
                    if Task.isCancelled { break }
                }

                transcript.append(LLMMessage(role: .assistant, content: responseText,
                                             toolCalls: toolCalls))

                // Réponse finale : aucun outil demandé.
                guard !toolCalls.isEmpty, !Task.isCancelled else { break }

                for call in toolCalls {
                    continuation.yield(.toolCall(name: call.name,
                                                 summary: Self.summary(of: call)))
                    let (result, ui) = await toolbox.execute(
                        name: call.name, argumentsJSON: call.argumentsJSON)
                    if let ui { continuation.yield(.uiCommand(ui)) }
                    transcript.append(LLMMessage(role: .tool, content: result,
                                                 toolCallID: call.id))
                }
            }
            continuation.yield(.finished)
        } catch {
            continuation.yield(.failed(message: error.localizedDescription))
        }
        continuation.finish()
    }

    /// Résumé lisible d'un appel d'outil pour l'interface (« search_library :
    /// dialectique »).
    private static func summary(of call: LLMToolCall) -> String {
        let args = (try? JSONSerialization.jsonObject(
            with: Data(call.argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        let detail = (args["query"] as? String)
            ?? (args["highlight"] as? String)
            ?? (args["page"] as? Int).map { "page \($0)" }
            ?? ""
        return detail.isEmpty ? call.name : "\(call.name) : \(detail)"
    }
}
