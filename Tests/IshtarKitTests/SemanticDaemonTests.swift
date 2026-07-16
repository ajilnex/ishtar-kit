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
            case .thought: break
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
