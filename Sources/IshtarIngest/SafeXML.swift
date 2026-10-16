import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// La seule porte par où le moteur lit le XML d'un fichier de tiers (EPUB, OPF,
/// fiche Calibre, DOCX, ODT, FB2) : jamais d'entité externe. Un document piégé
/// (`<!ENTITY x SYSTEM "file:///…">`, `<!DOCTYPE … SYSTEM "http://…">`) ne lit
/// donc rien de ce que voit la machine, et ne l'écrit ni dans le texte ni dans
/// les métadonnées ; il ne touche pas non plus au réseau (invariant n° 1). Les
/// entités internes (`&amp;`, `&#233;`…) restent lues.
///
/// `XMLPiegeTests` échoue si un `XMLDocument(data:)` apparaît
/// ailleurs que dans ce fichier.
enum SafeXML {
    static let options: XMLNode.Options = [.nodeLoadExternalEntitiesNever]

    static func document(data: Data) throws -> XMLDocument {
        try XMLDocument(data: data, options: options)
    }
}
