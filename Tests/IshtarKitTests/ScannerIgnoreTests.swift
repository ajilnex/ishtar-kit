import Foundation
import Testing
@testable import IshtarIngest

/// `.ishtar-ignorer` : un fichier retiré du catalogue reste à sa place sur le disque,
/// et le scan ne le revoit plus (règle du 25/10/2026, papiers personnels de `_NON_BIBLIO`).
@Suite struct ScannerIgnoreTests {
    @Test func cheminsListesIgnores() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ishtar-ignorer-\(UUID().uuidString)")
        let dossier = root.appendingPathComponent("_NON_BIBLIO")
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let txt = Data("texte".utf8)
        // Nom accentué écrit en NFD sur le disque, en NFC dans la liste.
        let prive = "_NON_BIBLIO/" + "Procuration signée.txt".decomposedStringWithCanonicalMapping
        try txt.write(to: root.appendingPathComponent(prive))
        try txt.write(to: root.appendingPathComponent("_NON_BIBLIO/Gardé.txt"))
        try txt.write(to: root.appendingPathComponent("Livre.txt"))
        try "# papiers personnels\n_NON_BIBLIO/Procuration signée.txt\n\n"
            .write(to: root.appendingPathComponent(".ishtar-ignorer"), atomically: true, encoding: .utf8)

        let noms = LibraryScanner(computeHashes: false).scan(directory: root).files
            .map { $0.fileName.precomposedStringWithCanonicalMapping }.sorted()
        #expect(noms == ["Gardé.txt", "Livre.txt"])
    }

    @Test func sansListeRienNEstIgnore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ishtar-ignorer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("texte".utf8).write(to: root.appendingPathComponent("Livre.txt"))
        #expect(LibraryScanner(computeHashes: false).scan(directory: root).files.count == 1)
    }
}
