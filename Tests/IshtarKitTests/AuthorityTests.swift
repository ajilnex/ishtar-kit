import Testing
import Foundation
import GRDB
@testable import IshtarCatalog
@testable import IshtarIngest
@testable import IshtarSearch

@Suite("Autorités : Sudoc, IdRef, Wikidata")
struct AuthorityTests {
    static let sudocXML = """
    <?xml version="1.0" encoding="UTF-8" ?>
    <srw:searchRetrieveResponse xmlns:srw="http://www.loc.gov/zing/srw/"><srw:numberOfRecords>1</srw:numberOfRecords>
    <srw:records><srw:record><srw:recordData><record>
    <controlfield tag="001">124615481</controlfield>
    <datafield tag="101" ind1="1" ind2=" "><subfield code="a">eng</subfield><subfield code="c">ger</subfield></datafield>
    <datafield tag="200" ind1="1" ind2=" "><subfield code="a">Minima moralia</subfield><subfield code="e">reflections from damaged life</subfield></datafield>
    <datafield tag="210" ind1=" " ind2=" "><subfield code="a">London</subfield><subfield code="d">1974</subfield></datafield>
    <datafield tag="500" ind1="1" ind2="0"><subfield code="a">Minima moralia</subfield><subfield code="m">anglais</subfield></datafield>
    <datafield tag="700" ind1=" " ind2="1"><subfield code="3">026678047</subfield><subfield code="a">Adorno</subfield><subfield code="b">Theodor Wiesengrund</subfield><subfield code="f">1903-1969</subfield><subfield code="4">070</subfield></datafield>
    <datafield tag="702" ind1=" " ind2="1"><subfield code="3">027001342</subfield><subfield code="a">Jephcott</subfield><subfield code="b">Edmund</subfield><subfield code="4">730</subfield></datafield>
    </record></srw:recordData></srw:record></srw:records></srw:searchRetrieveResponse>
    """

    @Test("Notice UNIMARC du Sudoc : titre, langues, auteur lié, traducteur")
    func sudocRecord() throws {
        let records = SudocConnector.parse(Data(Self.sudocXML.utf8))
        let r = try #require(records.first)
        #expect(r.ppn == "124615481")
        #expect(r.title == "Minima moralia")
        #expect(r.subtitle == "reflections from damaged life")
        #expect(r.languages == ["eng"])
        #expect(r.originalLanguages == ["ger"])
        #expect(r.isTranslation)
        #expect(r.uniformTitle == "Minima moralia")
        #expect(r.year == "1974")
        #expect(r.agents.count == 2)
        #expect(r.agents[0].isAuthor && r.agents[0].ppn == "026678047")
        #expect(r.agents[0].label == "Adorno, Theodor Wiesengrund (1903-1969)")
        #expect(r.agents[1].isTranslator)
    }

    @Test("IdRef : recherche (personnes seulement), documents liés, correspondances")
    func idrefParsing() {
        let search = #"{"response":{"docs":[{"ppn_z":"026678047","recordtype_z":"a","affcourt_z":"Adorno, Theodor Wiesengrund (1903-1969)"},{"ppn_z":"02743998X","recordtype_z":"b","affcourt_z":"Institut"}]}}"#
        #expect(IdRefConnector.parse(search: Data(search.utf8)) == [IdRefCandidate(ppn: "026678047", label: "Adorno, Theodor Wiesengrund (1903-1969)")])

        // Un seul rôle, un seul document : le service rend des objets, pas des tableaux.
        let refs = #"{"sudoc":{"result":{"role":{"roleName":"Auteur","doc":{"citation":"Minima moralia : réflexions sur la vie mutilée / Theodor W. Adorno / Paris : Payot , 2003"}}}}}"#
        #expect(IdRefConnector.parse(references: Data(refs.utf8)) == [IdRefReference(role: "Auteur", title: "Minima moralia : réflexions sur la vie mutilée")])

        let align = #"{"sudoc":[{"query":{"result":{"source":"BNF","identifiant":"http://catalogue.bnf.fr/ark:/12148/cb11888125w"}}},{"query":{"result":{"source":"VIAF","identifiant":"http://viaf.org/viaf/95247377"}}},{"query":{"result":{"source":"ISNI","identifiant":"0000000121442113"}}},{"query":{"result":{"source":"WIKIPEDIA","identifiant":"https://fr.wikipedia.org/wiki/X"}}}]}"#
        let found = IdRefConnector.parse(alignments: Data(align.utf8))
        #expect(found.map(\.scheme) == [.bnf, .viaf, .isni])
        #expect(found.map(\.identifier) == ["ark:/12148/cb11888125w", "95247377", "0000000121442113"])
        #expect(IdRefConnector.nameTokens("Theodor W. Adorno") == ["theodor", "adorno"])
        #expect(IdRefConnector.nameTokens("Paul Ricœur") == ["paul", "ricoeur"])
    }

    @Test("Wikidata : une œuvre et tous ses titres")
    func wikidataWorks() {
        let json = #"""
        {"results":{"bindings":[
          {"w":{"value":"http://www.wikidata.org/entity/Q1520631"},"t":{"xml:lang":"de","value":"Minima Moralia"},"lang":{"value":"de"},"date":{"value":"1951-01-01T00:00:00Z"}},
          {"w":{"value":"http://www.wikidata.org/entity/Q1520631"},"t":{"xml:lang":"fr","value":"Minima moralia"}},
          {"w":{"value":"http://www.wikidata.org/entity/Q1974273"},"t":{"xml:lang":"fr","value":"Dialectique négative"}},
          {"w":{"value":"http://www.wikidata.org/entity/Q1974273"},"t":{"xml:lang":"de","value":"Negative Dialektik"}}
        ]}}
        """#
        let works = WikidataConnector.parse(works: Data(json.utf8))
        #expect(works.map(\.qid) == ["Q1520631", "Q1974273"])
        #expect(works[0].language == "de" && works[0].year == "1951")
        #expect(works[1].titles == ["Dialectique négative", "Negative Dialektik"])
        #expect(works[1].label == "Dialectique négative")
    }

    @Test("Preuve : mêmes titres, nom de famille, décision")
    func decisions() {
        #expect(AuthorityPass.sameTitle("Minima moralia", "Minima moralia : réflexions sur la vie mutilée"))
        #expect(!AuthorityPass.sameTitle("Ethik", "Ethik und Politik"))
        #expect(AuthorityPass.family(ofName: "Theodor W. Adorno") == "adorno")
        #expect(AuthorityPass.family(ofName: "Nussbaum, Martha C.") == "nussbaum")
        #expect(AuthorityPass.family(ofLabel: "Ricœur, Paul (1913-2005 ; philosophe)") == "ricoeur")

        let one = AuthorityPass.decide(sudocTally: ["026678047": ("Adorno, T.", 2, "Minima moralia")])
        #expect(one == .confirmed(IdRefCandidate(ppn: "026678047", label: "Adorno, T."), evidence: "auteur de « Minima moralia » dans le Sudoc"))
        let tie = AuthorityPass.decide(sudocTally: ["1": ("A", 1, "T"), "2": ("B", 1, "T")])
        if case .proposed(let cs, _) = tie { #expect(cs.count == 2) } else { Issue.record("égalité : proposé attendu") }
        #expect(AuthorityPass.decide(sudocTally: [:]) == nil)

        // Paul Ricœur et Jean-Paul Ricoeur : seul celui qui a un livre commun est retenu.
        let paul = IdRefCandidate(ppn: "026908905", label: "Ricœur, Paul (1913-2005)")
        let jp = IdRefCandidate(ppn: "03032817X", label: "Ricoeur, Jean-Paul (1937-2023)")
        let d = AuthorityPass.decide(name: "Paul Ricœur", candidates: [jp, paul], evidence: [paul.ppn: "Temps et récit"])
        if case .confirmed(let c, _) = d { #expect(c == paul) } else { Issue.record("confirmé attendu") }
    }

    @Test("Liens : jamais rétrogradés ; fiches partageant une notice")
    func links() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let store = CatalogStore(db: db)
        let a = UUID(), b = UUID()
        try await store.record([AuthorityLink(entityType: .creator, entityId: a, scheme: .idref, identifier: "026678047", status: .proposed)])
        try await store.record([AuthorityLink(entityType: .creator, entityId: a, scheme: .idref, identifier: "026678047", status: .confirmed)])
        try await store.record([AuthorityLink(entityType: .creator, entityId: a, scheme: .idref, identifier: "026678047", status: .proposed)])
        #expect(try await store.authorityLinks(for: .creator, id: a).map(\.status) == [.confirmed])
        try await store.record([AuthorityLink(entityType: .creator, entityId: b, scheme: .idref, identifier: "026678047", status: .confirmed)])
        let shared = try await store.sharedAuthorities(type: .creator, scheme: .idref)
        #expect(shared.count == 1 && Set(shared[0].entityIds) == [a, b])
    }
}

@Suite("Réidentification : règles tirées des erreurs relevées le 24/09")
struct ReidentificationTests {
    @Test("Noms de fichiers : années antiques et premiers siècles")
    func ancientYears() {
        let aristote = FilenameParser.parse(fileName: "Aristote_-350_Traite-du-ciel.pdf")
        #expect(aristote.author == "Aristote" && aristote.year == "-350" && aristote.title == "Traite du ciel")
        let tite = FilenameParser.parse(fileName: "Tite-Live_14_Histoire-Romaine.epub")
        #expect(tite.author == "Tite-Live" && tite.year == "14")
        // « Chapitre_1_… » n'est pas un auteur daté.
        #expect(FilenameParser.parse(fileName: "chapitre_1_Introduction.pdf").confidence != .structured)
        #expect(CiteKeyGenerator.base(author: "Aristote", year: "-350", title: "Traité du ciel") == "Aristote350Traite")
    }

    @Test("Noms d'auteur : dates, formes inversées, listes")
    func authorNames() {
        #expect(TypographyRestorer.normalizedAuthor("Tite-Live (59 av.J.-C. – 17 av.J.-C.)") == "Tite-Live")
        #expect(TypographyRestorer.normalizedAuthor("Deleuze, Gilles, 1925-1995") == "Gilles Deleuze")
        #expect(TypographyRestorer.normalizedAuthor("Brunhoff, Suzanne de") == "Suzanne de Brunhoff")
        #expect(TypographyRestorer.normalizedAuthor("Gilles Deleuze, Félix Guattari") == "Gilles Deleuze, Félix Guattari")
        #expect(TypographyRestorer.isNameList("Gilles Deleuze, Félix Guattari"))
        #expect(!TypographyRestorer.isNameList("Nussbaum, Martha C."))
        #expect(Reidentification.people("Hogrebe, Wolfram;Gabriel, Markus;Hamilton Grant, Iain;") == ["Wolfram Hogrebe", "Markus Gabriel", "Iain Hamilton Grant"])
        #expect(Reidentification.people("Gilles Deleuze; translated by Martin Joughin") == ["Gilles Deleuze"])
        #expect(Reidentification.isPlaceholder("NEC Computers International"))
    }

    @Test("Vote des trois témoins")
    func vote() {
        typealias R = AttributionResolution
        // La fiche « Sellars » d'autrefois cède devant le nom de fichier.
        #expect(Reidentification.resolve(catalog: "Sellars", file: "Davidson", embedded: nil) == R.replace("Davidson"))
        #expect(Reidentification.resolve(catalog: "Sellars", file: "Robert", embedded: "Robert Jean-Dominique") == R.replace("Jean-Dominique Robert"))
        // « Inconnu » prend le nom du fichier.
        #expect(Reidentification.resolve(catalog: "Inconnu", file: "Brassier", embedded: nil) == R.replace("Brassier"))
        // Même personne, nom plus complet ; jamais un prénom déplacé depuis la tête.
        #expect(Reidentification.resolve(catalog: "DeVries", file: "DeVries", embedded: "Willem A. de Vries") == R.enrich("Willem A. de Vries"))
        #expect(Reidentification.resolve(catalog: "Adin", file: "Adin", embedded: "Adin Steinsaltz") == nil)
        // Co-auteurs annoncés par le fichier ; éditeurs écartés sinon.
        #expect(Reidentification.resolve(catalog: "Badiou-Roudinesco", file: "Badiou-Roudinesco", embedded: "Alain Badiou, Elisabeth Roudinesco") == R.split(["Alain Badiou", "Elisabeth Roudinesco"]))
        #expect(Reidentification.resolve(catalog: "Weiss", file: "Weiss", embedded: "Bernhard Weiss and Jeremy Wanderer") == R.enrich("Bernhard Weiss"))
        #expect(Reidentification.resolve(catalog: "Merleau-Ponty", file: "Merleau-Ponty", embedded: "Maurice Merleau-Ponty") == R.enrich("Maurice Merleau-Ponty"))
        // Trois témoins en désaccord : le Sudoc départagera.
        #expect(Reidentification.resolve(catalog: "Aristotle", file: "Aristote", embedded: "Aristotle") == R.undecided)
    }
}

@Suite("Clés et regroupements : règles du 24/09")
struct KeyAndGroupingRulesTests {
    @Test("Le mot qui distingue deux livres de même base")
    func distinguishing() {
        let fusing = CiteKeyGenerator.titleWords("Wilfrid Sellars: Fusing the Images")
        let truth = CiteKeyGenerator.titleWords("Wilfrid Sellars on Truth")
        let bare = CiteKeyGenerator.titleWords("Wilfrid Sellars")
        #expect(CiteKeyGenerator.distinguishing(fusing, from: [truth, bare]) == "Fusing")
        #expect(CiteKeyGenerator.distinguishing(truth, from: [fusing, bare]) == "Truth")
        #expect(CiteKeyGenerator.distinguishing(bare, from: [fusing, truth]) == nil)
        let t1 = CiteKeyGenerator.titleWords("Anna Karénine - Tome I"), t2 = CiteKeyGenerator.titleWords("Anna Karénine - Tome II")
        #expect(CiteKeyGenerator.distinguishing(t2, from: [t1]) == "II")
        let kant = CiteKeyGenerator.titleWords("Critique de la raison pure, tome 1")
        #expect(CiteKeyGenerator.distinguishing(kant, from: [CiteKeyGenerator.titleWords("Critique de la raison pure")]) == "Tome1")
    }

    @Test("Deux livres de même base ne se partagent pas un « -b »")
    func keysDistinguishWorks() async throws {
        let db = try CatalogDatabase(inMemory: ())
        try await db.pool.write { conn in
            for title in ["Wilfrid Sellars: Fusing the Images", "Wilfrid Sellars on Truth"] {
                let work = Work(title: title, curationStatus: .recognized, confidence: .probable)
                try work.insert(conn)
                try Edition(workId: work.id, year: "2007", curationStatus: .recognized, confidence: .probable).insert(conn)
                let c = try Creator.filter(Column("name") == "Rosenberg").fetchOne(conn) ?? { let c = Creator(name: "Rosenberg"); try c.insert(conn); return c }()
                try WorkCreator(workId: work.id, creatorId: c.id, role: .author, position: 0).insert(conn)
            }
            try EditionKey.assignMissing(conn)
        }
        let keys = try await db.pool.read { try String.fetchAll($0, sql: "SELECT key FROM edition_key ORDER BY key") }
        #expect(keys == ["Rosenberg2007WilfridFusing", "Rosenberg2007WilfridTruth"])
    }

    @Test("Même livre : titre tronqué oui, autre tome non")
    func sameBook() {
        #expect(EditionGrouping.sameBook(title: "L ethique protestante", "L’Éthique protestante et l’esprit du capitalisme"))
        #expect(!EditionGrouping.sameBook(title: "Anna Karénine - Tome I", "Anna Karénine - Tome II"))
        #expect(!EditionGrouping.sameBook(title: "Logic of the Future", "Logic of the Future Vol 1"))
        #expect(EditionGrouping.volume("Anna Karénine - Tome II") == "ii")
    }
}

@Suite("Noms d'auteur : forme d'usage et forme de classement (NORMES §6)")
struct AuthorityNameTests {
    @Test("Forme de classement tirée de l'autorité, particules comprises")
    func sortNames() {
        #expect(AuthorityNames.sortName(display: "Theodor W. Adorno", authorityLabel: "Adorno, Theodor Wiesengrund (1903-1969)") == "Adorno, Theodor W.")
        #expect(AuthorityNames.sortName(display: "Simone de Beauvoir", authorityLabel: "Beauvoir, Simone de (1908-1986)") == "Beauvoir, Simone de")
        #expect(AuthorityNames.sortName(display: "Jean de La Fontaine", authorityLabel: "La Fontaine, Jean de (1621-1695)") == "La Fontaine, Jean de")
        #expect(AuthorityNames.sortName(display: "Maurice Merleau-Ponty", authorityLabel: "Merleau-Ponty, Maurice (1908-1961)") == "Merleau-Ponty, Maurice")
        #expect(AuthorityNames.sortName(display: "Platon", authorityLabel: "Platon (0427?-0348? av. J.-C.)") == "Platon")
        #expect(AuthorityNames.sortName(display: "Sun Tzu", authorityLabel: "Sunzi (0544?-0496? av. J.-C.)") == nil)
        #expect(AuthorityNames.natural(authorityLabel: "Adorno, Theodor Wiesengrund (1903-1969)") == "Theodor Wiesengrund Adorno")
    }

    @Test("Libellés Wikidata : français d'abord")
    func labels() {
        let json = #"{"entities":{"Q152388":{"labels":{"fr":{"value":"Theodor W. Adorno"},"en":{"value":"Theodor W. Adorno"}}},"Q859":{"labels":{"en":{"value":"Plato"}}}}}"#
        let l = WikidataConnector.parse(labels: Data(json.utf8))
        #expect(l["Q152388"] == "Theodor W. Adorno" && l["Q859"] == "Plato")
    }
}

@Suite("Étiquette des fichiers (bibliothèque confiée)")
struct FileLabelTests {
    @Test("Nom de famille d'abord, antiquité, deux auteurs, interdits d'exFAT")
    func labels() {
        #expect(FileLabel.name(families: ["Adorno"], title: "Minima moralia", year: "1951", ext: "PDF") == "Adorno — Minima moralia (1951).pdf")
        #expect(FileLabel.name(families: ["Aristote"], title: "Traité du ciel", year: "-350", ext: "pdf") == "Aristote — Traité du ciel (350 av. J.-C.).pdf")
        #expect(FileLabel.name(families: ["Deleuze", "Guattari"], title: "Mille plateaux", year: "1980", ext: "epub") == "Deleuze & Guattari — Mille plateaux (1980).epub")
        #expect(FileLabel.name(families: ["Hogrebe", "Gabriel", "Grant"], title: "Predication and Genesis", year: nil, ext: "pdf") == "Hogrebe et al. — Predication and Genesis.pdf")
        #expect(FileLabel.name(families: ["Rosenberg"], title: "Wilfrid Sellars: Fusing the Images", year: "2007", ext: "pdf") == "Rosenberg — Wilfrid Sellars – Fusing the Images (2007).pdf")
        #expect(FileLabel.name(families: ["Deleuze"], title: "Qu'est-ce que la philosophie ?", year: "1991", ext: "epub") == "Deleuze — Qu'est-ce que la philosophie (1991).epub")
        #expect(FileLabel.name(families: ["Adorno"], title: "Minima moralia", year: "1951", editionYear: "2003", ext: "pdf", copy: 2) == "Adorno — Minima moralia (1951, éd. 2003) [2].pdf")
        #expect(FileLabel.family(ofName: "Simone de Beauvoir", sortName: "Beauvoir, Simone de") == "Beauvoir")
    }

    @Test("L'étiquette se relit")
    func roundTrip() {
        let a = FilenameParser.parse(fileName: "Aristote — Traité du ciel (350 av. J.-C.).pdf")
        #expect(a.author == "Aristote" && a.title == "Traité du ciel" && a.year == "-350" && a.confidence == .structured)
        let b = FilenameParser.parse(fileName: "Adorno — Minima moralia (1951, éd. 2003) [2].pdf")
        #expect(b.author == "Adorno" && b.title == "Minima moralia" && b.year == "1951")
        #expect(FilenameParser.parse(fileName: "Anonyme — Les Mille et Une Nuits.epub").author == nil)
    }
}

@Suite("Genre : livre ou article")
struct DocumentKindTests {
    @Test("Formats de livres, pages et marques")
    func kinds() {
        #expect(DocumentKind.classify(format: .epub, pages: 12, opening: "") == .livre)
        #expect(DocumentKind.classify(format: .pdf, pages: 20, opening: "Philosophical Studies, Vol. 39, pp. 325-345, JSTOR") == .article)
        #expect(DocumentKind.classify(format: .pdf, pages: 20, opening: "C H A P T E R 8.1 The Moon and Sixpence") == .article)
        #expect(DocumentKind.classify(format: .pdf, pages: 341, opening: "Oxford University Press, ISBN") == .livre)
        #expect(DocumentKind.classify(format: .pdf, pages: 90, opening: "Table des matières. Éditions du Seuil. ISBN 978") == .livre)
    }
}

@Suite("Noms : particules, crochets, dates en tête")
struct NameCleanupTests {
    @Test func cleanup() {
        #expect(FilenameParser.parse(fileName: "Van-Fraassen_1989_Laws-and-Symmetry.pdf").author == "Van Fraassen")
        #expect(FilenameParser.parse(fileName: "Merleau-Ponty_1945_Phenomenologie.pdf").author == "Merleau-Ponty")
        #expect(TypographyRestorer.normalizedAuthor("David] David Spiegelhalter [Spiegelhalter") == "David Spiegelhalter")
        #expect(TypographyRestorer.normalizedAuthor("1040-1105 Rashi") == "Rashi")
    }
}
