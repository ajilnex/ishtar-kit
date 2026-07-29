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
