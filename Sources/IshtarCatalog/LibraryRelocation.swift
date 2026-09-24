import Foundation
import GRDB

/// Le dossier d'une bibliothèque a changé de place sur le disque.
///
/// Les chemins des documents sont enregistrés en absolu : sans cette réécriture,
/// un dossier déplacé rend tout le catalogue orphelin (fiches, surlignements,
/// collections, projets), puisque le scan suivant ne reconnaît plus aucun chemin.
public enum LibraryRelocationError: Error, Equatable, LocalizedError {
    /// L'ancien et le nouvel emplacement sont identiques.
    case samePath
    /// Le catalogue contient déjà des documents sous le nouvel emplacement :
    /// fusionner deux bibliothèques n'est pas un déplacement.
    case destinationOccupied(count: Int)

    public var errorDescription: String? {
        switch self {
        case .samePath:
            return "L'ancien et le nouvel emplacement sont identiques."
        case .destinationOccupied(let count):
            return "Le catalogue contient déjà \(count) document(s) sous le nouvel emplacement."
        }
    }
}

extension CatalogStore {
    /// Réécrit le préfixe de chemin de tous les documents rangés sous `oldRoot`,
    /// ainsi que le dossier source enregistré. Une seule transaction : tout ou rien.
    ///
    /// La comparaison se fait par préfixe exact (`substr`), jamais par `LIKE` :
    /// `_` et `%` sont des caractères ordinaires dans les noms de dossiers.
    ///
    /// - Returns: le nombre de documents déplacés.
    @discardableResult
    public func relocateLibrary(from oldRoot: String, to newRoot: String) async throws -> Int {
        let requestedOld = Self.normalizedRoot(oldRoot)
        let new = Self.normalizedRoot(newRoot)
        guard requestedOld != new else { throw LibraryRelocationError.samePath }

        return try await db.pool.write { conn in
            // SQLite compare octet à octet ; Swift, à équivalence canonique près.
            // On reprend la racine telle qu'enregistrée (NFC ou NFD), sinon un
            // « é » composé différemment ne trouverait aucun document.
            let recorded = try String.fetchAll(conn, sql: "SELECT path FROM source_folder")
            let old = recorded.first { $0 == requestedOld } ?? requestedOld

            let occupied = try Int.fetchOne(conn, sql: """
                SELECT COUNT(*) FROM document
                WHERE filePath = ? OR substr(filePath, 1, ?) = ?
                """, arguments: [new, Self.sqliteLength(new) + 1, new + "/"]) ?? 0
            // Le nouvel emplacement peut être un sous-dossier de l'ancien, ou
            // l'inverse : seuls comptent les documents qui ne seront pas déplacés.
            let alsoUnderOld = try Int.fetchOne(conn, sql: """
                SELECT COUNT(*) FROM document
                WHERE (filePath = ? OR substr(filePath, 1, ?) = ?)
                  AND (filePath = ? OR substr(filePath, 1, ?) = ?)
                """, arguments: [new, Self.sqliteLength(new) + 1, new + "/",
                                 old, Self.sqliteLength(old) + 1, old + "/"]) ?? 0
            if occupied - alsoUnderOld > 0 {
                throw LibraryRelocationError.destinationOccupied(count: occupied - alsoUnderOld)
            }

            // `substr()` compte en points de code, `String.count` en graphèmes :
            // les noms accentués décomposés (NFD, courants sous macOS) les
            // font diverger, d'où `sqliteLength` partout.
            try conn.execute(sql: """
                UPDATE document
                SET filePath = ? || substr(filePath, ?)
                WHERE filePath = ? OR substr(filePath, 1, ?) = ?
                """, arguments: [new, Self.sqliteLength(old) + 1,
                                 old, Self.sqliteLength(old) + 1, old + "/"])
            let moved = conn.changesCount

            try conn.execute(sql: "DELETE FROM source_folder WHERE path = ?", arguments: [new])
            try conn.execute(sql: "UPDATE source_folder SET path = ? WHERE path = ?",
                             arguments: [new, old])
            return moved
        }
    }

    /// Les dossiers sources enregistrés dans ce catalogue.
    public func sourceFolderPaths() async throws -> [String] {
        try await db.pool.read { conn in
            try String.fetchAll(conn, sql: "SELECT path FROM source_folder ORDER BY dateAdded")
        }
    }

    /// Chemin standardisé, sans barre finale : la forme sous laquelle
    /// l'ingestion enregistre ses racines.
    static func normalizedRoot(_ path: String) -> String {
        var standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        while standardized.count > 1 && standardized.hasSuffix("/") {
            standardized.removeLast()
        }
        return standardized
    }

    /// Longueur telle que SQLite la compte pour `substr` sur du texte :
    /// en points de code Unicode, pas en graphèmes.
    static func sqliteLength(_ s: String) -> Int {
        s.unicodeScalars.count
    }
}

extension CatalogDatabase {
    /// Les dossiers sources d'un catalogue, lus sans l'ouvrir en écriture ni le
    /// migrer : sert à reconnaître, parmi les bibliothèques connues, celle dont
    /// le dossier a été déplacé.
    public static func recordedSourceFolders(ofCatalogAt url: URL) throws -> [String] {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        return try queue.read { conn in
            try String.fetchAll(conn, sql: "SELECT path FROM source_folder ORDER BY dateAdded")
        }
    }
}
