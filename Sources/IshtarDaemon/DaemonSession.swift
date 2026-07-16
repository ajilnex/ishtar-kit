import Foundation

/// Une conversation avec le démon : la boucle outillée, minimale et bornée,
/// PLUS la boucle de citations vérifiées (invariant n° 6) : aucune réponse
/// contenant des citations n'est montrée sans validation locale préalable.
///
/// Conséquence assumée : le texte d'un tour est mis en tampon et émis APRÈS
/// vérification (en un bloc), plutôt que streamé au fil de l'eau — la
/// correction vaut mieux que l'effet machine à écrire. Budget strict :
/// 6 tours outillés, 2 tours de correction de citations.
public actor DaemonSession {
    private let client: any LLMClient
    private let toolbox: DaemonToolbox
    private let verifier: CitationVerifier?
    private var transcript: [LLMMessage]

    private static let maxIterations = 6
    private static let maxCitationRetries = 2

    public init(client: any LLMClient, toolbox: DaemonToolbox,
                verifier: CitationVerifier? = nil, systemPrompt: String? = nil) {
        self.client = client
        self.toolbox = toolbox
        self.verifier = verifier
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
    2. Cite toujours tes sources. Chaque citation d'un passage doit être suivie \
    d'un marqueur EXACT : [[cite:<document_id>|p=<page>|"<six à douze mots \
    exacts du passage>"]] — le document_id et la page viennent de \
    search_library ou read_page ; les mots exacts viennent du texte lu. \
    N'invente JAMAIS ces valeurs : elles sont vérifiées mécaniquement.
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
            var citationRetries = 0

            for _ in 0..<Self.maxIterations {
                var responseText = ""
                var toolCalls: [LLMToolCall] = []

                for try await chunk in client.stream(messages: transcript,
                                                     tools: toolbox.specs) {
                    switch chunk {
                    case .text(let text):
                        // Tamponné : rien n'est montré avant vérification.
                        responseText += text
                    case .finished(let calls):
                        toolCalls = calls
                    }
                    if Task.isCancelled { break }
                }

                transcript.append(LLMMessage(role: .assistant, content: responseText,
                                             toolCalls: toolCalls))

                // Tour outillé : exécuter puis reboucler.
                if !toolCalls.isEmpty, !Task.isCancelled {
                    for call in toolCalls {
                        continuation.yield(.toolCall(name: call.name,
                                                     summary: Self.summary(of: call)))
                        let (result, ui) = await toolbox.execute(
                            name: call.name, argumentsJSON: call.argumentsJSON)
                        if let ui { continuation.yield(.uiCommand(ui)) }
                        transcript.append(LLMMessage(role: .tool, content: result,
                                                     toolCallID: call.id))
                    }
                    continue
                }

                // Réponse finale : boucle de citations vérifiées.
                guard let verifier else {
                    continuation.yield(.token(responseText))
                    break
                }
                let checks = await verifier.verify(text: responseText)
                let failures = checks.filter { $0.verdict.isFailure }

                if !failures.isEmpty, citationRetries < Self.maxCitationRetries {
                    citationRetries += 1
                    continuation.yield(.toolCall(
                        name: "vérification",
                        summary: "\(failures.count) citation(s) à corriger"))
                    transcript.append(LLMMessage(
                        role: .user,
                        content: CitationVerifier.feedback(for: failures)))
                    continue
                }

                // Émission : texte rendu lisible + puces + avertissement résiduel.
                var text = CitationVerifier.rendered(text: responseText, checks: checks)
                if !failures.isEmpty {
                    text += "\n\n⚠️ Certaines citations n'ont pas pu être vérifiées contre la bibliothèque."
                }
                continuation.yield(.token(text))
                if !checks.isEmpty {
                    continuation.yield(.citations(checks.map { check in
                        CitationChip(documentId: check.citation.documentId,
                                     page: check.citation.page,
                                     title: check.title,
                                     quote: check.citation.quote,
                                     verified: !check.verdict.isFailure)
                    }))
                }
                break
            }
            continuation.yield(.finished)
        } catch {
            continuation.yield(.failed(message: error.localizedDescription))
        }
        continuation.finish()
    }

    /// Résumé lisible d'un appel d'outil pour l'interface.
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
