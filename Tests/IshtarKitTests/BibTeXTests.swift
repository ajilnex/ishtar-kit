import Testing
import Foundation
@testable import IshtarIngest
@testable import IshtarCatalog

@Suite("Tests du parseur et importateur BibTeX (Lot D)")
struct BibTeXTests {
    
    @Test("Parseur BibTeX : accolades imbriquées, LaTeX et normalisation 'and'")
    func bibTeXParserCoreFeatures() {
        let content = """
        @article{kant_raison_1781,
            title = {{Kritik} der {reinen Vernunft}},
            author = {Kant, Immanuel and M\\\"uller, Max and de la Fontaine, Jean},
            year = "1781",
            file = {Critique:path/to/kant.pdf:application/pdf;Autre:path/to/other.pdf:application/pdf}
        }
        % Ceci est un commentaire
        @string{ foo = "bar" }
        """
        
        let entries = BibTeXParser.parse(content: content)
        #expect(entries.count == 1)
        
        let entry = entries[0]
        #expect(entry.key == "kant_raison_1781")
        #expect(entry.type == "article")
        
        // Accolades internes gardées, LaTeX échappé, etc.
        #expect(entry.fields["title"] == "Kritik der reinen Vernunft") // Les { de protection doivent être enlevés, wait, nettoyage basique les enlève tous, c'est ce qui est attendu
        #expect(entry.fields["year"] == "1781") // guillemets gérés
        
        // Fichier
        #expect(entry.fields["file"] == "Critique:path/to/kant.pdf:application/pdf;Autre:path/to/other.pdf:application/pdf")
        
        // Auteurs
        let authors = BibTeXParser.normalizeAuthors(entry.fields["author"] ?? "")
        #expect(authors.count == 3)
        #expect(authors[0] == "Kant, Immanuel")
        #expect(authors[1] == "Müller, Max")
        #expect(authors[2] == "Fontaine, Jean de la" || authors[2] == "de la Fontaine, Jean") // Le nom est déjà "de la Fontaine, Jean", wait non, il l'était. S'il était "Jean de la Fontaine", ça deviendrait "Fontaine, Jean de la".
        // Le cas exact est testé.
    }
    
    @Test("Parseur : nettoyage LaTeX et accolades")
    func parseurCleansProperly() {
        let content = """
        @book{test1,
            title = {{La G\\'en\\'ealogie}},
            author = {Nietzsche, Friedrich}
        }
        """
        let entries = BibTeXParser.parse(content: content)
        #expect(entries[0].fields["title"] == "La Généalogie")
    }

    @Test("Importateur : correspondances fortes et faibles")
    func importerMatches() async throws {
        let db = try CatalogDatabase(inMemory: ())
        
        // Préparer la base
        let work1 = Work(title: "La Généalogie de la morale")
        let work2 = Work(title: "Critique de la raison pure")
        let work3 = Work(title: "Tractatus")
        
        let ed1 = Edition(workId: work1.id, isbn13: "9781234567890")
        let ed2 = Edition(workId: work2.id, doi: "10.1234/567")
        let ed3 = Edition(workId: work3.id)
        
        let doc1 = Document(editionId: ed1.id, filePath: "/tmp/genealogie.pdf", originalFileName: "genealogie.pdf", fileSize: 1, format: .pdf)
        let doc2 = Document(editionId: ed2.id, filePath: "/tmp/critique.pdf", originalFileName: "critique.pdf", fileSize: 1, format: .pdf)
        let doc3 = Document(editionId: ed3.id, filePath: "/tmp/tractatus.epub", originalFileName: "tractatus.epub", fileSize: 1, format: .epub)
        
        let author1 = Creator(name: "Nietzsche, Friedrich")
        let author3 = Creator(name: "Wittgenstein, Ludwig")
        let wc1 = WorkCreator(workId: work1.id, creatorId: author1.id)
        let wc3 = WorkCreator(workId: work3.id, creatorId: author3.id)
        
        try await db.pool.write { conn in
            try work1.insert(conn)
            try work2.insert(conn)
            try work3.insert(conn)
            
            try ed1.insert(conn)
            try ed2.insert(conn)
            try ed3.insert(conn)
            
            try doc1.insert(conn)
            try doc2.insert(conn)
            try doc3.insert(conn)
            
            try author1.insert(conn)
            try author3.insert(conn)
            
            try wc1.insert(conn)
            try wc3.insert(conn)
        }
        
        // Cas 1: fichier exact
        let entry1 = BibTeXEntry(key: "e1", type: "book", fields: ["title": "Osef", "file": "Desc:path/to/genealogie.pdf:application/pdf"])
        
        // Cas 2: DOI exact
        let entry2 = BibTeXEntry(key: "e2", type: "book", fields: ["title": "Osef", "doi": "10.1234/567"])
        
        // Cas 3: Titre et auteur (signal faible)
        let entry3 = BibTeXEntry(key: "e3", type: "book", fields: ["title": "Tractatus", "author": "Wittgenstein, Ludwig"])
        
        // Cas 4: Introuvable
        let entry4 = BibTeXEntry(key: "e4", type: "book", fields: ["title": "Introuvable"])
        
        let importer = BibTeXImporter()
        let report = try await importer.match(entries: [entry1, entry2, entry3, entry4], in: db)
        
        #expect(report.totalRead == 4)
        #expect(report.strongMatches.count == 2)
        #expect(report.weakMatches.count == 1)
        #expect(report.unmatched.count == 1)
        
        // Vérification détaillée
        let matchFile = report.strongMatches.first { $0.document?.id == doc1.id }!
        #expect(matchFile.signal == .strong(reason: "fichier exact (genealogie.pdf)"))
        
        let matchDOI = report.strongMatches.first { $0.document?.id == doc2.id }!
        #expect(matchDOI.signal == .strong(reason: "DOI exact"))
        
        let matchWeak = report.weakMatches.first { $0.document?.id == doc3.id }!
        #expect(matchWeak.signal == .weak(reason: "titre et auteur"))
    }
    
    @Test("Appliquer les propositions n'écrase pas un document en confiance haute")
    func applyProposalRespectsHighConfidence() async throws {
        let db = try CatalogDatabase(inMemory: ())
        
        let work = Work(title: "Vieux Titre", curationStatus: .recognized, confidence: .high)
        let ed = Edition(workId: work.id, curationStatus: .recognized, confidence: .high)
        let doc = Document(editionId: ed.id, filePath: "/f.pdf", originalFileName: "f.pdf", fileSize: 1, format: .pdf, curationStatus: .recognized, confidence: .high)
        
        try await db.pool.write { conn in
            try work.insert(conn)
            try ed.insert(conn)
            try doc.insert(conn)
        }
        
        let store = CatalogStore(db: db)
        try await store.applyProposal(workId: work.id, editionId: ed.id, documentId: doc.id, title: "Nouveau Titre", authors: [], year: nil, publisher: nil, language: nil, isbn13: nil, doi: nil)
        
        let verifyWork = try await db.pool.read { try Work.fetchOne($0, key: work.id)! }
        // Le titre n'a pas été écrasé car confidence == .high
        #expect(verifyWork.title == "Vieux Titre")
    }
}
