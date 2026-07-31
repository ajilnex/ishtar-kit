import Foundation
import Testing
@testable import IshtarCatalog

@Suite("Démon — historique des conversations")
struct ConversationStoreTests {
    private func makeStore() throws -> ConversationStore {
        ConversationStore(db: try CatalogDatabase(inMemory: ()))
    }

    @Test("Un fil s'empile dans l'ordre et se relit tel qu'il a été dit")
    func appendAndRead() async throws {
        let store = try makeStore()
        let fil = try await store.start()

        try await store.append(to: fil.id, role: .user, content: "Que dit Kant ?")
        try await store.append(to: fil.id, role: .tool, content: "search_library")
        try await store.append(to: fil.id, role: .assistant,
                               content: "La raison pure examine ses limites.",
                               citationsJSON: #"[{"page":42}]"#)

        let messages = try await store.messages(of: fil.id)
        #expect(messages.map(\.position) == [0, 1, 2])
        #expect(messages.map(\.role) == [.user, .tool, .assistant])
        #expect(messages[2].citationsJSON == #"[{"page":42}]"#)
        #expect(messages[0].citationsJSON == nil)
    }

    @Test("La première question nomme le fil, et rien ne le renomme ensuite")
    func autoTitle() async throws {
        let store = try makeStore()
        let fil = try await store.start()
        #expect(try await store.recent().first?.title == nil)

        try await store.append(to: fil.id, role: .user, content: "Que dit Kant ?")
        #expect(try await store.recent().first?.title == "Que dit Kant ?")

        // Une seconde question ne vole pas le titre de la première.
        try await store.append(to: fil.id, role: .user, content: "Et Hegel ?")
        #expect(try await store.recent().first?.title == "Que dit Kant ?")

        try await store.rename(id: fil.id, to: "Les limites de la raison")
        #expect(try await store.recent().first?.title == "Les limites de la raison")
    }

    @Test("L'historique montre le fil nourri en dernier, en tête")
    func recentOrder() async throws {
        let store = try makeStore()
        let ancien = try await store.start()
        let recent = try await store.start()

        try await store.append(to: ancien.id, role: .user, content: "Première question")
        try await store.append(to: recent.id, role: .user, content: "Seconde question")
        #expect(try await store.recent().first?.id == recent.id)

        // Rouvrir le vieux fil le ramène en tête.
        try await store.append(to: ancien.id, role: .user, content: "Je reviens")
        #expect(try await store.recent().first?.id == ancien.id)
    }

    @Test("Supprimer un fil emporte ses messages ; les fils muets sont balayés")
    func deletionAndPurge() async throws {
        let store = try makeStore()
        let parlant = try await store.start()
        let muet = try await store.start()
        try await store.append(to: parlant.id, role: .user, content: "Une question")

        try await store.purgeEmpty()
        let restants = try await store.recent()
        #expect(restants.count == 1)
        #expect(restants.first?.id == parlant.id)
        #expect(!restants.contains { $0.id == muet.id })

        try await store.remove(id: parlant.id)
        #expect(try await store.recent().isEmpty)
        // Cascade : plus de fil, plus de messages.
        #expect(try await store.messages(of: parlant.id).isEmpty)
    }
}

@Suite("Démon — titre dérivé d'une conversation")
struct ConversationTitleTests {
    @Test("Une question courte devient le titre ; une longue est coupée sur un mot")
    func derivation() {
        #expect(ConversationTitle.derived(from: "Que dit Kant ?") == "Que dit Kant ?")

        // Les blancs et sauts de ligne d'une saisie multiligne sont compactés.
        #expect(ConversationTitle.derived(from: "  Que dit\n  Kant ?  ") == "Que dit Kant ?")

        let longue = "Quels ouvrages de ma bibliothèque traitent de l'écriture cunéiforme "
            + "et lesquels sont antérieurs à 1980 ?"
        let titre = try! #require(ConversationTitle.derived(from: longue))
        #expect(titre.count <= 61)
        #expect(titre.hasSuffix("…"))
        // Coupé sur une frontière de mot : pas de mot tranché en deux.
        #expect(!titre.dropLast().hasSuffix(" "))
        #expect(longue.hasPrefix(String(titre.dropLast())))
    }

    @Test("Une question vide ne nomme rien")
    func emptyQuestion() {
        #expect(ConversationTitle.derived(from: "") == nil)
        #expect(ConversationTitle.derived(from: "   \n  ") == nil)
    }
}

@Suite("Démon — chercher dans l'historique")
struct ConversationSearchTests {
    private func makeHistory() async throws -> (ConversationStore, UUID, UUID) {
        let store = ConversationStore(db: try CatalogDatabase(inMemory: ()))
        let kant = try await store.start()
        try await store.append(to: kant.id, role: .user, content: "Que dit Kant ?")
        try await store.append(to: kant.id, role: .assistant,
                               content: "La raison pure examine ses limites.")
        let sumer = try await store.start()
        try await store.append(to: sumer.id, role: .user, content: "Cherche Sumer")
        try await store.append(to: sumer.id, role: .assistant,
                               content: "La vérité de l'écriture cunéiforme.")
        return (store, kant.id, sumer.id)
    }

    @Test("On retrouve un fil par son titre comme par le corps d'un message")
    func byTitleAndBody() async throws {
        let (store, kant, sumer) = try await makeHistory()

        // Par le titre, dérivé de la première question.
        #expect(try await store.search("Kant").map(\.id) == [kant])
        // Par le contenu d'une réponse, que le titre ne porte pas.
        #expect(try await store.search("cunéiforme").map(\.id) == [sumer])
    }

    @Test("Les accents et la casse ne font pas échouer la recherche")
    func foldedSearch() async throws {
        let (store, _, sumer) = try await makeHistory()
        #expect(try await store.search("VERITE").map(\.id) == [sumer])
        #expect(try await store.search("vérité").map(\.id) == [sumer])
    }

    @Test("Une requête vide rend tout ; une requête étrangère ne rend rien")
    func edges() async throws {
        let (store, _, _) = try await makeHistory()
        #expect(try await store.search("").count == 2)
        #expect(try await store.search("   ").count == 2)
        #expect(try await store.search("bureaucratie").isEmpty)
    }

    @Test("Un fil renommé se retrouve par son nouveau nom")
    func renamedThenFound() async throws {
        let (store, kant, _) = try await makeHistory()
        try await store.rename(id: kant, to: "Les limites de la raison")
        #expect(try await store.search("limites").map(\.id).contains(kant))
    }
}
