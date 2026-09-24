import Testing
import Foundation
import GRDB
@testable import IshtarCatalog
@testable import IshtarIngest

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
