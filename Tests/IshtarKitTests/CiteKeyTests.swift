import Testing
import Foundation
import GRDB
@testable import IshtarCatalog

@Suite("Clés de citation (lot F2)")
struct CiteKeyTests {
    // MARK: Fabrique pure

    @Test("Forme canonique : famille + année + premier mot significatif")
    func canonical() {
        #expect(CiteKeyGenerator.base(author: "Theodor W. Adorno", year: "1951",
                                      title: "Minima moralia") == "Adorno1951Minima")
        #expect(CiteKeyGenerator.base(author: "Kant", year: "1781",
                                      title: "Critique de la raison pure") == "Kant1781Critique")
    }

    @Test("Mots vides sautés en tête, en plusieurs langues")
    func stopwords() {
        #expect(CiteKeyGenerator.base(author: "Stendhal", year: "1822", title: "De l amour") == "Stendhal1822Amour")
        #expect(CiteKeyGenerator.base(author: "Hacking", year: "2002", title: "The Social Construction") == "Hacking2002Social")
        #expect(CiteKeyGenerator.base(author: "Hegel", year: "1807", title: "Die Phänomenologie des Geistes") == "Hegel1807Phanomenologie")
    }

    @Test("Translittération ASCII : accents, ß, grec")
    func transliteration() {
        #expect(CiteKeyGenerator.base(author: "Kurt Gödel", year: "1931", title: "Über formal") == "Godel1931Formal")
        #expect(CiteKeyGenerator.base(author: "Πλάτων", year: nil, title: "Πολιτεία") == "PlatonNDPoliteia")
        #expect(CiteKeyGenerator.words("Straße") == ["Strasse"])
    }

    @Test("Sans auteur ni année : Anon, ND")
    func fallbacks() {
        #expect(CiteKeyGenerator.base(author: nil, year: "ND", title: "Preface") == "AnonNDPreface")
        #expect(CiteKeyGenerator.base(author: "", year: "c. 1951-1953", title: "") == "Anon1951")
    }

    @Test("Collision : année d'édition d'abord, puis lettres ; casse ignorée")
    func collisions() {
        let taken: Set = ["adorno1951minima"]
        #expect(CiteKeyGenerator.unique(base: "Adorno1951Minima", editionYear: "2003", taken: taken)
                == "Adorno1951Minima-2003")
        #expect(CiteKeyGenerator.unique(base: "Adorno1951Minima", editionYear: nil, taken: taken)
                == "Adorno1951Minima-b")
        #expect(CiteKeyGenerator.unique(base: "Adorno1951Minima", editionYear: "2003",
                                        taken: taken.union(["Adorno1951Minima-2003"]))
                == "Adorno1951Minima-b")
    }

    @Test("Clés manuelles : caractères admis")
    func manualValidation() {
        #expect(CiteKeyGenerator.isValidManualKey("Adorno1951Minima-2003"))
        #expect(CiteKeyGenerator.isValidManualKey("adorno:mm"))
        #expect(!CiteKeyGenerator.isValidManualKey("Adorno 1951"))
        #expect(!CiteKeyGenerator.isValidManualKey("Gödel1931"))
        #expect(!CiteKeyGenerator.isValidManualKey(""))
    }

    // MARK: Catalogue

    private func addEdition(_ db: CatalogDatabase, author: String?, title: String,
                            editionYear: String?, workDate: String? = nil) async throws -> UUID {
        try await db.pool.write { conn in
            let work = Work(title: title, date: workDate)
            try work.insert(conn)
            if let author {
                let creator = Creator(name: author)
                try creator.insert(conn)
                try WorkCreator(workId: work.id, creatorId: creator.id, role: .author, position: 0).insert(conn)
            }
            let edition = Edition(workId: work.id, year: editionYear)
            try edition.insert(conn)
            return edition.id
        }
    }

    @Test("Attribution : chaque édition reçoit une clé, les doublons sont départagés")
    func assignment() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let a = try await addEdition(db, author: "Adorno", title: "Minima moralia", editionYear: "1951")
        let b = try await addEdition(db, author: "Adorno", title: "Minima moralia", editionYear: "2003", workDate: "1951")
        let store = CatalogStore(db: db)

        #expect(try await store.assignMissingKeys() == 2)
        let keys = [try await store.key(forEdition: a)?.key, try await store.key(forEdition: b)?.key]
        #expect(Set(keys.compactMap { $0 }) == ["Adorno1951Minima", "Adorno1951Minima-2003"])
        #expect(try await store.assignMissingKeys() == 0)
    }

    @Test("Stabilité : corriger la fiche ne change pas la clé")
    func stability() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let id = try await addEdition(db, author: "Adorno", title: "Minima moralia", editionYear: "1951")
        let store = CatalogStore(db: db)
        try await store.assignMissingKeys()

        try await db.pool.write { conn in
            try conn.execute(sql: "UPDATE work SET title = 'Dialektik der Aufklärung'")
        }
        try await store.assignMissingKeys()
        #expect(try await store.key(forEdition: id)?.key == "Adorno1951Minima")
    }

    @Test("Correction manuelle : validée, unique, marquée manual")
    func manualKey() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let a = try await addEdition(db, author: "Adorno", title: "Minima moralia", editionYear: "1951")
        let b = try await addEdition(db, author: "Kant", title: "Critique", editionYear: "1781")
        let store = CatalogStore(db: db)
        try await store.assignMissingKeys()

        try await store.setKey("AdornoMM", forEdition: a)
        #expect(try await store.key(forEdition: a)?.origin == .manual)
        await #expect(throws: CiteKeyError.taken("adornomm")) {
            try await store.setKey("adornomm", forEdition: b)
        }
        await #expect(throws: CiteKeyError.invalid("Kant 1781")) {
            try await store.setKey("Kant 1781", forEdition: b)
        }
    }

    @Test("La clé disparaît avec son édition")
    func cascade() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let id = try await addEdition(db, author: "Adorno", title: "Minima moralia", editionYear: "1951")
        try await CatalogStore(db: db).assignMissingKeys()
        try await db.pool.write { _ = try Edition.deleteOne($0, key: id) }
        let count = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM edition_key") }
        #expect(count == 0)
    }
}
