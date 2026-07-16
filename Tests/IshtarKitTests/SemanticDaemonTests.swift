import Foundation
import Testing
@testable import IshtarCatalog
@testable import IshtarDaemon
@testable import IshtarIngest
@testable import IshtarSearch

// MARK: - Magasin de vecteurs (sqlite-vec)

@Suite("Sémantique — magasin de vecteurs")
struct EmbeddingStoreTests {
    private func makeStore() throws -> EmbeddingStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ishtar-vec-\(UUID().uuidString).sqlite")
        return try EmbeddingStore(at: url)
    }

    @Test("Insertion et plus proches voisins (vecteurs synthétiques)")
    func nearestNeighbours() throws {
        let store = try makeStore()
        try store.prepare(modelID: "test", dimension: 4)

        let docA = UUID(), docB = UUID()
        try store.insert([
            (EmbeddingStore.PageKey(documentId: docA, pageNumber: 1), [1, 0, 0, 0]),
            (EmbeddingStore.PageKey(documentId: docA, pageNumber: 2), [0, 1, 0, 0]),
            (EmbeddingStore.PageKey(documentId: docB, pageNumber: 7), [0.9, 0.1, 0, 0]),
        ])
        #expect(try store.count() == 3)

        let nearest = try store.nearest(to: [1, 0, 0, 0], limit: 2)
        #expect(nearest.count == 2)
        #expect(nearest[0].key == EmbeddingStore.PageKey(documentId: docA, pageNumber: 1))
        #expect(nearest[1].key == EmbeddingStore.PageKey(documentId: docB, pageNumber: 7))
    }

    @Test("Changer de modèle purge l'index (jamais de vecteurs hétérogènes)")
    func modelChangePurges() throws {
        let store = try makeStore()
        try store.prepare(modelID: "a", dimension: 4)
        try store.insert([(EmbeddingStore.PageKey(documentId: UUID(), pageNumber: 1),
                           [1, 0, 0, 0])])
        #expect(try store.count() == 1)

        try store.prepare(modelID: "b", dimension: 8)
        #expect(try store.count() == 0)
    }

    @Test("Réinsérer la même page remplace son vecteur (idempotence)")
    func reinsertReplaces() throws {
        let store = try makeStore()
        try store.prepare(modelID: "test", dimension: 4)
        let key = EmbeddingStore.PageKey(documentId: UUID(), pageNumber: 3)
        try store.insert([(key, [1, 0, 0, 0])])
        try store.insert([(key, [0, 1, 0, 0])])
        #expect(try store.count() == 1)
        let nearest = try store.nearest(to: [0, 1, 0, 0], limit: 1)
        #expect(nearest.first?.key == key)
    }
}

// MARK: - Accumulateur SSE OpenAI (pur, sans réseau)

@Suite("Démon — flux OpenAI-compatible")
struct StreamAccumulatorTests {
    @Test("Texte streamé et appels d'outils fragmentés sont réassemblés")
    func toolCallAssembly() {
        var acc = OpenAIStreamAccumulator()

        let events = [
            #"{"choices":[{"delta":{"content":"Je "}}]}"#,
            #"{"choices":[{"delta":{"content":"cherche."}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"search_","arguments":"{\"qu"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"library","arguments":"ery\":\"kant\"}"}}]}}]}"#,
        ]
        var text = ""
        for event in events {
            if let t = acc.ingest(json: Data(event.utf8)) { text += t }
        }
        #expect(text == "Je cherche.")

        let calls = acc.finalizedToolCalls()
        #expect(calls.count == 1)
        #expect(calls[0].name == "search_library")
        #expect(calls[0].argumentsJSON == #"{"query":"kant"}"#)
        #expect(calls[0].id == "call_1")
    }
}

// MARK: - Accumulateur SSE Anthropic (pur, sans réseau)

@Suite("Démon — flux Anthropic")
struct AnthropicStreamAccumulatorTests {
    @Test("Texte streamé et tool_use fragmenté par input_json_delta sont réassemblés")
    func toolUseAssembly() {
        var acc = AnthropicStreamAccumulator()

        let events = [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Je "}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"cherche."}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"search_library","input":{}}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"qu"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"ery\":\"kant\"}"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
        ]
        var text = ""
        for event in events {
            if let t = acc.ingest(json: Data(event.utf8)) { text += t }
        }
        #expect(text == "Je cherche.")
        #expect(!acc.isDone)

        let calls = acc.finalizedToolCalls()
        #expect(calls.count == 1)
        #expect(calls[0].id == "toolu_1")
        #expect(calls[0].name == "search_library")
        #expect(calls[0].argumentsJSON == #"{"query":"kant"}"#)
    }

    @Test("message_stop clôt le flux ; un tool_use sans delta produit des arguments vides")
    func messageStopAndEmptyInput() {
        var acc = AnthropicStreamAccumulator()
        _ = acc.ingest(json: Data(
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_2","name":"library_stats","input":{}}}"#.utf8))
        #expect(!acc.isDone)
        _ = acc.ingest(json: Data(#"{"type":"message_stop"}"#.utf8))
        #expect(acc.isDone)

        let calls = acc.finalizedToolCalls()
        #expect(calls.count == 1)
        #expect(calls[0].argumentsJSON == "{}")
    }
}

@Suite("Démon — corps de requête Anthropic")
struct AnthropicRequestBodyTests {
    @Test("Un tour outillé : system séparé, blocs text+tool_use, tool_result en message user")
    func toolTurnMapping() throws {
        let messages = [
            LLMMessage(role: .system, content: "Tu es le démon d'Ishtar."),
            LLMMessage(role: .user, content: "Que dit Kant ?"),
            LLMMessage(role: .assistant, content: "Je cherche.",
                       toolCalls: [LLMToolCall(id: "toolu_1", name: "search_library",
                                               argumentsJSON: #"{"query":"kant"}"#)]),
            LLMMessage(role: .tool, content: "3 passages trouvés", toolCallID: "toolu_1"),
        ]
        let tools = [LLMToolSpec(
            name: "search_library", description: "Recherche hybride",
            parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}}}"#)]

        let data = try AnthropicClient.requestBody(
            model: "claude-sonnet-5", messages: messages, tools: tools)
        let payload = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Le système est un paramètre séparé, jamais dans messages.
        #expect(payload["system"] as? String == "Tu es le démon d'Ishtar.")
        #expect(payload["model"] as? String == "claude-sonnet-5")
        #expect(payload["stream"] as? Bool == true)

        let apiMessages = try #require(payload["messages"] as? [[String: Any]])
        #expect(apiMessages.count == 3)

        #expect(apiMessages[0]["role"] as? String == "user")
        #expect(apiMessages[0]["content"] as? String == "Que dit Kant ?")

        // Assistant : blocs text puis tool_use, avec input désérialisé en objet.
        #expect(apiMessages[1]["role"] as? String == "assistant")
        let blocks = try #require(apiMessages[1]["content"] as? [[String: Any]])
        #expect(blocks.count == 2)
        #expect(blocks[0]["type"] as? String == "text")
        #expect(blocks[0]["text"] as? String == "Je cherche.")
        #expect(blocks[1]["type"] as? String == "tool_use")
        #expect(blocks[1]["id"] as? String == "toolu_1")
        #expect(blocks[1]["name"] as? String == "search_library")
        let input = try #require(blocks[1]["input"] as? [String: Any])
        #expect(input["query"] as? String == "kant")

        // Résultat d'outil : message user portant un bloc tool_result.
        #expect(apiMessages[2]["role"] as? String == "user")
        let results = try #require(apiMessages[2]["content"] as? [[String: Any]])
        #expect(results.count == 1)
        #expect(results[0]["type"] as? String == "tool_result")
        #expect(results[0]["tool_use_id"] as? String == "toolu_1")
        #expect(results[0]["content"] as? String == "3 passages trouvés")

        // Les outils sont déclarés avec input_schema (objet).
        let declaredTools = try #require(payload["tools"] as? [[String: Any]])
        #expect(declaredTools.count == 1)
        #expect(declaredTools[0]["name"] as? String == "search_library")
        #expect(declaredTools[0]["input_schema"] is [String: Any])
    }
}

// MARK: - Boucle du démon (faux client, vraie boîte à outils)

/// Un client scripté : premier tour → appel d'outil ; second tour → réponse.
private struct ScriptedClient: LLMClient {
    let call: LLMToolCall

    func stream(messages: [LLMMessage], tools: [LLMToolSpec])
        -> AsyncThrowingStream<LLMChunk, Error>
    {
        AsyncThrowingStream { continuation in
            let hasToolResult = messages.contains { $0.role == .tool }
            if hasToolResult {
                continuation.yield(.text("Voilà : « Critique », p. 2."))
                continuation.yield(.finished(toolCalls: []))
            } else {
                continuation.yield(.finished(toolCalls: [call]))
            }
            continuation.finish()
        }
    }
}

@Suite("Démon — boucle outillée")
struct DaemonLoopTests {
    @Test("Un tour outillé : open_document émet la commande d'interface, puis réponse finale")
    func toolLoop() async throws {
        // Petite bibliothèque réelle en mémoire.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ishtar-daemon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("La raison pure examine ses propres limites.".utf8)
            .write(to: dir.appendingPathComponent("Kant_1781_Critique.txt"))

        let db = try CatalogDatabase(inMemory: ())
        _ = try Ingestor().ingest(report: LibraryScanner().scan(directory: dir),
                                  sourceFolder: dir, into: db)
        let docId = try await db.pool.read { try Document.fetchAll($0) }[0].id

        let call = LLMToolCall(
            id: "c1", name: "open_document",
            argumentsJSON: #"{"document_id":"\#(docId.uuidString)","page":2,"highlight":"raison pure"}"#)
        let session = DaemonSession(
            client: ScriptedClient(call: call),
            toolbox: DaemonToolbox(db: db, semantic: nil))

        var tokens = ""
        var toolCalls: [String] = []
        var uiCommands: [UICommand] = []
        var finished = false
        for await event in await session.send("Montre-moi le passage sur la raison") {
            switch event {
            case .token(let t): tokens += t
            case .toolCall(let name, _): toolCalls.append(name)
            case .uiCommand(let ui): uiCommands.append(ui)
            case .finished: finished = true
            case .failed(let message): Issue.record("échec : \(message)")
            case .thought, .citations: break
            }
        }

        #expect(finished)
        #expect(toolCalls == ["open_document"])
        #expect(tokens.contains("Critique"))
        if case let .openDocument(id, page, highlight)? = uiCommands.first {
            #expect(id == docId)
            #expect(page == 2)
            #expect(highlight == "raison pure")
        } else {
            Issue.record("commande openDocument attendue")
        }
    }
}

// MARK: - Citations vérifiées (invariant n° 6)

@Suite("Citations — extraction et cascade de vérification")
struct CitationVerifierTests {
    /// Catalogue avec un document dont deux pages sont extraites.
    private func makeLibrary() async throws -> (CatalogDatabase, UUID) {
        let db = try CatalogDatabase(inMemory: ())
        let work = Work(title: "Critique de la raison pure")
        let edition = Edition(workId: work.id)
        let document = Document(editionId: edition.id, filePath: "/tmp/k.pdf",
                                originalFileName: "k.pdf", fileSize: 1, format: .pdf)
        try await db.pool.write { conn in
            try work.insert(conn)
            try edition.insert(conn)
            try document.insert(conn)
            try conn.execute(sql: """
                INSERT INTO document_page(documentId, pageNumber, content)
                VALUES (?, 1, 'La raison pure examine ses propres limites.'),
                       (?, 2, 'Les intuitions sans concepts sont aveugles.')
                """, arguments: [document.id, document.id])
        }
        return (db, document.id)
    }

    @Test("Extraction des marqueurs [[cite:…]]")
    func extraction() {
        let id = UUID()
        let text = """
        Kant l'écrit [[cite:\(id.uuidString)|p=2|"intuitions sans concepts"]] et
        ailleurs [[cite:\(id.uuidString)|p=1]].
        """
        let citations = CitationVerifier.extract(from: text)
        #expect(citations.count == 2)
        #expect(citations[0].quote == "intuitions sans concepts")
        #expect(citations[1].quote == nil)
        #expect(citations[0].documentId == id)
    }

    @Test("La cascade : valide, source invalide, page hors bornes, introuvable, trouvé ailleurs")
    func cascade() async throws {
        let (db, docId) = try await makeLibrary()
        let verifier = CitationVerifier(db: db)

        func verdict(_ marker: String) async -> CitationVerifier.Verdict? {
            await verifier.verify(text: marker).first?.verdict
        }

        // Valide : bons mots, bonne page (diacritiques repliées).
        #expect(await verdict("[[cite:\(docId.uuidString)|p=2|\"intuitions sans concepts sont aveugles\"]]")
                == .valid(title: "Critique de la raison pure"))
        // Source inconnue.
        #expect(await verdict("[[cite:\(UUID().uuidString)|p=1|\"peu importe les mots\"]]")
                == .invalidSource)
        // Page hors bornes (2 pages extraites).
        #expect(await verdict("[[cite:\(docId.uuidString)|p=99|\"peu importe les mots\"]]")
                == .pageOutOfRange(title: "Critique de la raison pure", maxPage: 2))
        // Extrait introuvable.
        #expect(await verdict("[[cite:\(docId.uuidString)|p=1|\"le noumène chevauche le phénomène\"]]")
                == .quoteNotFound(title: "Critique de la raison pure"))
        // Trouvé ailleurs : le feedback le plus utile.
        #expect(await verdict("[[cite:\(docId.uuidString)|p=1|\"intuitions sans concepts sont aveugles\"]]")
                == .foundElsewhere(title: "Critique de la raison pure", actualPage: 2))
    }
}

/// Client scripté pour la boucle : première réponse avec une citation FAUSSE
/// (mauvaise page) ; après le feedback de validation, réponse corrigée.
private struct SelfCorrectingClient: LLMClient {
    let docId: UUID

    func stream(messages: [LLMMessage], tools: [LLMToolSpec])
        -> AsyncThrowingStream<LLMChunk, Error>
    {
        AsyncThrowingStream { continuation in
            let gotFeedback = messages.contains {
                $0.role == .user && $0.content.contains("[Validation des citations")
            }
            let page = gotFeedback ? 2 : 1
            continuation.yield(.text(
                "Kant écrit que les intuitions sans concepts sont aveugles " +
                "[[cite:\(docId.uuidString)|p=\(page)|\"intuitions sans concepts sont aveugles\"]]."))
            continuation.yield(.finished(toolCalls: []))
            continuation.finish()
        }
    }
}

@Suite("Citations — la boucle de correction")
struct CitationLoopTests {
    @Test("Une citation fausse est corrigée avant émission ; puces vérifiées émises")
    func correctionLoop() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let work = Work(title: "Critique de la raison pure")
        let edition = Edition(workId: work.id)
        let document = Document(editionId: edition.id, filePath: "/tmp/k.pdf",
                                originalFileName: "k.pdf", fileSize: 1, format: .pdf)
        try await db.pool.write { conn in
            try work.insert(conn)
            try edition.insert(conn)
            try document.insert(conn)
            try conn.execute(sql: """
                INSERT INTO document_page(documentId, pageNumber, content)
                VALUES (?, 1, 'Préambule.'),
                       (?, 2, 'Les intuitions sans concepts sont aveugles.')
                """, arguments: [document.id, document.id])
        }

        let session = DaemonSession(
            client: SelfCorrectingClient(docId: document.id),
            toolbox: DaemonToolbox(db: db, semantic: nil),
            verifier: CitationVerifier(db: db))

        var text = ""
        var corrections = 0
        var chips: [CitationChip] = []
        for await event in await session.send("Que dit Kant des intuitions ?") {
            switch event {
            case .token(let t): text += t
            case .toolCall(let name, _) where name == "vérification": corrections += 1
            case .citations(let c): chips = c
            default: break
            }
        }

        // Un tour de correction, puis la version CORRIGÉE seulement est émise.
        #expect(corrections == 1)
        #expect(text.contains("p. 2"))
        #expect(!text.contains("[[cite:"), "le marqueur machine ne doit jamais s'afficher")
        #expect(!text.contains("⚠️"))
        #expect(chips.count == 1)
        #expect(chips[0].verified)
        #expect(chips[0].page == 2)
        #expect(chips[0].title == "Critique de la raison pure")
    }
}
