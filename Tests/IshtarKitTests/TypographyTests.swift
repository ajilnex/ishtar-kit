import Testing
import Foundation
import GRDB
@testable import IshtarCatalog
@testable import IshtarIngest

@Suite("Restauration typographique")
struct TypographyTests {
    @Test("Même titre mieux écrit : repris")
    func sameTitleRicher() {
        #expect(TypographyRestorer.restoredTitle(current: "Tout seffondre", embedded: "Tout s'effondre") == "Tout s'effondre")
        #expect(TypographyRestorer.restoredTitle(current: "De l amour", embedded: "De l’amour") == "De l’amour")
        #expect(TypographyRestorer.restoredTitle(current: "Les Demons de Godel", embedded: "Les Démons de Gödel") == "Les Démons de Gödel")
    }

    @Test("Autre titre, capitales, graphie moins riche : refusés")
    func refusals() {
        #expect(TypographyRestorer.restoredTitle(current: "Minima moralia", embedded: "Minima Moralia : réflexions sur la vie mutilée") == nil)
        #expect(TypographyRestorer.restoredTitle(current: "Tout seffondre", embedded: "TOUT S'EFFONDRE") == nil)
        #expect(TypographyRestorer.restoredTitle(current: "L'Éthique", embedded: "L Ethique") == nil)
        #expect(TypographyRestorer.restoredTitle(current: "Ethique", embedded: nil) == nil)
        #expect(TypographyRestorer.restoredTitle(current: "Ethique", embedded: "Microsoft Word - doc1") == nil)
    }

    @Test("Sous-titre : repris quand la tête est le titre de la fiche")
    func subtitles() {
        let a = TypographyRestorer.restoredSubtitle(current: "Minima moralia", embedded: "Minima Moralia : réflexions sur la vie mutilée")
        #expect(a?.subtitle == "réflexions sur la vie mutilée")
        let b = TypographyRestorer.restoredSubtitle(current: "Debt", embedded: "Debt: The First 5,000 Years")
        #expect(b?.title == "Debt" && b?.subtitle == "The First 5,000 Years")
        let c = TypographyRestorer.restoredSubtitle(current: "Apres la finitude", embedded: "Après la finitude. Essai sur la nécessité de la contingence")
        #expect(c?.title == "Après la finitude")
        #expect(TypographyRestorer.restoredSubtitle(current: "Minima moralia", embedded: "Dialektik der Aufklärung : Philosophische Fragmente") == nil)
        #expect(TypographyRestorer.restoredSubtitle(current: "Debt", embedded: "Debt") == nil)
        #expect(TypographyRestorer.restoredSubtitle(current: "Die Torah", embedded: "Die Torah: eine deutsche Übersetzung (German Edition)")?.subtitle
                == "eine deutsche Übersetzung")
        #expect(TypographyRestorer.restoredSubtitle(current: "The Shape of Weather", embedded: "The Shape of Weather: A History ( Exemple.com ).mobi") == nil)
        #expect(TypographyRestorer.restoredSubtitle(current: "Le Pont des Voyelles", embedded: "Le Pont des Voyelles: Laventure (Claire Fontaine) (Nom du site)")?.subtitle == "Laventure")
    }

    @Test("Auteur : même nom enrichi, ou nom complet du même nom de famille")
    func authors() {
        #expect(TypographyRestorer.restoredAuthor(current: "Buttgen", embedded: "Philippe Büttgen") == "Philippe Büttgen")
        #expect(TypographyRestorer.restoredAuthor(current: "Buttgen", embedded: "Büttgen, Philippe") == "Philippe Büttgen")
        #expect(TypographyRestorer.restoredAuthor(current: "Godel", embedded: "Gödel") == "Gödel")
        #expect(TypographyRestorer.restoredAuthor(current: "Adorno", embedded: "Max Horkheimer") == nil)
        #expect(TypographyRestorer.restoredAuthor(current: "Adorno", embedded: "Horkheimer; Adorno") == nil)
        #expect(TypographyRestorer.restoredAuthor(current: "Hegel", embedded: "HEGEL") == nil)
        #expect(TypographyRestorer.restoredAuthor(current: "Porge", embedded: "Erik PORGE") == "Erik Porge")
        #expect(TypographyRestorer.restoredAuthor(current: "Billeter", embedded: "Jean François BILLETER") == "Jean François Billeter")
        #expect(TypographyRestorer.restoredAuthor(current: "Meier", embedded: "Heinrich(Author) Meier") == "Heinrich Meier")
        #expect(TypographyRestorer.restoredAuthor(current: "Cohen", embedded: "G. A. Cohen") == "G. A. Cohen")
    }

    @Test("Écriture : titre et auteur restaurés, confiance inchangée, main humaine respectée")
    func store() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let (free, locked) = try await db.pool.write { conn -> (UUID, UUID) in
            let creator = Creator(name: "Buttgen"); try creator.insert(conn)
            let w1 = Work(title: "Lumieres fetiches", curationStatus: .recognized, confidence: .probable); try w1.insert(conn)
            let w2 = Work(title: "Autre titre", curationStatus: .recognized, confidence: .high); try w2.insert(conn)
            for w in [w1, w2] {
                try WorkCreator(workId: w.id, creatorId: creator.id).insert(conn)
                try Edition(workId: w.id, year: "2025").insert(conn)
            }
            try EditionKey.assignMissing(conn)
            return (w1.id, w2.id)
        }
        let store = CatalogStore(db: db)
        #expect(try await store.applyTypography(workId: free, title: "Lumières fétiches", author: (from: "Buttgen", to: "Philippe Büttgen")))
        #expect(try await !store.applyTypography(workId: locked, title: "Autre titré", author: nil))

        let (title, confidence, authors, lockedAuthors) = try await db.pool.read { conn in
            let w = try Work.fetchOne(conn, key: free)!
            let a = try String.fetchAll(conn, sql: "SELECT c.name FROM work_creator wc JOIN creator c ON c.id = wc.creatorId WHERE wc.workId = ?", arguments: [free])
            let b = try String.fetchAll(conn, sql: "SELECT c.name FROM work_creator wc JOIN creator c ON c.id = wc.creatorId WHERE wc.workId = ?", arguments: [locked])
            return (w.title, w.confidence, a, b)
        }
        #expect(title == "Lumières fétiches")
        #expect(confidence == .probable)
        #expect(authors == ["Philippe Büttgen"])
        #expect(lockedAuthors == ["Buttgen"], "l'homonyme d'une autre œuvre n'est pas emporté")
    }
}
