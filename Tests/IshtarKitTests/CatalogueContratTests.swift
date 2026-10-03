import Testing
import Foundation
@testable import IshtarCatalog
@testable import IshtarSearch

/// Le contrat du « Catalogue publié » v1 (`contrats/catalogue-publie.mjs`,
/// copie de `_PONTS/contrats/`) : ce qu'Ishtar publie, Rayons et le
/// Bibliothécaire savent le lire. Audit du 03/10, D9.
@Suite("Contrat du catalogue publié (v1)")
struct CatalogueContratTests {
    private let root = "/lib/Bibliothèque"
    private let empreinte = String(repeating: "ab", count: 32)

    /// Une petite bibliothèque : un livre dont l'auteur a sa forme de
    /// classement et des notices confirmées, et une œuvre sans auteur.
    private func bibliotheque(at url: URL) async throws -> CatalogDatabase {
        let db = try CatalogDatabase(at: url)
        try await db.pool.write { conn in
            let work = Work(title: "Minima moralia", date: "1951")
            try work.insert(conn)
            let adorno = Creator(name: "Theodor W. Adorno", sortName: "Adorno, Theodor W.")
            try adorno.insert(conn)
            try WorkCreator(workId: work.id, creatorId: adorno.id).insert(conn)
            let notices: [(AuthorityLink.Scheme, String)] = [(.idref, "02694507X"), (.bnf, "ark:/12148/cb11888635m"), (.wikidata, "Q152388")]
            for (scheme, identifier) in notices {
                try AuthorityLink(entityType: .creator, entityId: adorno.id, scheme: scheme, identifier: identifier,
                                  label: "Adorno", status: .confirmed, evidence: "essai").insert(conn)
            }
            let edition = Edition(workId: work.id, publisher: "Payot", year: "2003", language: "fr",
                                  curationStatus: .recognized, confidence: .high)
            try edition.insert(conn)
            try Document(editionId: edition.id, filePath: "\(root)/Adorno — Minima moralia (1951).pdf",
                         originalFileName: "Adorno — Minima moralia (1951).pdf", fileSize: 1234,
                         contentHash: empreinte, format: .pdf, curationStatus: .recognized).insert(conn)

            let anonyme = Work(title: "Sans auteur")
            try anonyme.insert(conn)
            let sienne = Edition(workId: anonyme.id)
            try sienne.insert(conn)
            try Document(editionId: sienne.id, filePath: "\(root)/Sans auteur.epub",
                         originalFileName: "Sans auteur.epub", fileSize: 99,
                         contentHash: String(repeating: "cd", count: 32), format: .epub,
                         curationStatus: .recognized).insert(conn)
            try EditionKey.assignMissing(conn)
        }
        return db
    }

    @Test("Ishtar publie work, kind et people comme le contrat les décrit")
    func champsDuContrat() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ishtar-contrat-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let out = tmp.appendingPathComponent("Catalogue publié")
        let db = try await bibliotheque(at: tmp.appendingPathComponent("catalog.sqlite"))
        _ = try await CatalogPublisher(db: db).publish(root: root, rules: PublicationRules(), to: out)

        let manifeste = out.appendingPathComponent("catalogue.json")
        let racine = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifeste)) as? [String: Any])
        #expect(racine["version"] as? Int == 1)
        let editions = try #require(racine["editions"] as? [[String: Any]])
        #expect(editions.count == 2)
        for e in editions {
            let work = try #require(e["work"] as? String, "work est requis par le contrat")
            #expect(UUID(uuidString: work) != nil)
            #expect(["livre", "article"].contains(e["kind"] as? String ?? ""))
            let fichiers = try #require(e["files"] as? [[String: Any]])
            for f in fichiers {
                let sha = try #require(f["sha256"] as? String)
                #expect(sha.count == 64 && sha.allSatisfy { "0123456789abcdef".contains($0) })
                #expect(!(f["path"] as? String ?? "/").hasPrefix("/"))
            }
        }
        let livre = try #require(editions.first { $0["title"] as? String == "Minima moralia" })
        let personnes = try #require(livre["people"] as? [[String: Any]])
        #expect(personnes.count == 1)
        #expect(personnes[0]["name"] as? String == "Theodor W. Adorno")
        #expect(personnes[0]["sortName"] as? String == "Adorno, Theodor W.")
        #expect(personnes[0]["idref"] as? String == "02694507X")
        #expect(personnes[0]["bnf"] as? String == "ark:/12148/cb11888635m")
        #expect(personnes[0]["wikidata"] as? String == "Q152388")
        let sansAuteur = try #require(editions.first { $0["title"] as? String == "Sans auteur" })
        #expect(sansAuteur["people"] == nil, "people est absent quand l'œuvre n'a pas d'auteur")

        // Le vérificateur commun (Node), quand Node est là : la même règle que
        // Rayons et le Bibliothécaire appliquent en lisant ce catalogue.
        guard let node = Self.node() else { return }
        let verificateur = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contrats/catalogue-publie.mjs")
        #expect(fm.fileExists(atPath: verificateur.path))
        let process = Process()
        process.executableURL = node
        process.arguments = [verificateur.path, manifeste.path]
        let sortie = Pipe()
        process.standardOutput = sortie
        process.standardError = sortie
        try process.run()
        process.waitUntilExit()
        let texte = String(decoding: sortie.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(texte)")
        #expect(texte.contains("conforme au contrat v1"), "\(texte)")
    }

    /// Node, s'il est installé (le test du format Swift reste valable sans lui).
    private static func node() -> URL? {
        let chemins = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        return chemins.map { URL(fileURLWithPath: $0).appendingPathComponent("node") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
