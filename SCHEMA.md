# Schéma du catalogue Ishtar — v1

Le catalogue est un fichier SQLite unique par bibliothèque. Ce schéma est un
format d'échange documenté : les outils tiers peuvent le lire. Les migrations
sont uniquement additives (forward-only).

## Ontologie (FRBR-léger)

```
creator ──< work_creator >── work ──< edition ──< document
                               │          └──< edition_creator >── creator
                               └──< collection_item >── collection
```

- **work** — l'œuvre intellectuelle (*Critique de la raison pure*).
- **edition** — une manifestation (trad. Tremesaygues & Pacaud, PUF, 1944 ; ISBN, DOI).
- **document** — un fichier concret (chemin, SHA-256, format). Plusieurs documents
  peuvent porter la même édition : c'est la déduplication naturelle.
- **creator** — personne ou institution ; rôles typés (`author`, `translator`, `editor`, …).
- **collection** — étagères de l'utilisateur ; à l'import, l'arborescence des dossiers
  sources devient des collections (`sourceFolderPath` en garde la trace).
- **source_folder** — les dossiers observés par la bibliothèque (lecture seule).

## États de curation

Portés par `work`, `edition` et `document` :

- `curationStatus` : `recognized` · `needsReview` · `duplicateCandidate` · `ignored`
- `confidence` : `high` · `probable` · `low`

Ishtar sait dire « je sais », « je crois », « j'ai besoin d'aide » — à chaque étage.

## Notes techniques

- Identifiants : UUID, encodés par GRDB (blob 16 octets). Susceptible de passer en
  texte avant la première release publique — sera documenté ici.
- Journal WAL. Encodage des dates : format GRDB par défaut.
- Migrations à venir (M2–M3) : liens typés, artéfacts, embeddings
  (sqlite-vec, dimension par modèle), conversations du démon.

## Migration v2 — pages extraites et plein texte (WP-03)

Additive, après v1.

- **document_page** — une ligne par « page » de texte extraite d'un document.
  - `documentId` → `document(id)` (`ON DELETE CASCADE`), `pageNumber` (1-based),
    `content` ; clé primaire (`documentId`, `pageNumber`).
  - Pour un PDF, `pageNumber` est la page réelle ; pour EPUB/TXT/MD, un compteur
    séquentiel sur l'ordre de lecture (item de spine, ou tranche de ~4000 car.).
  - L'extraction est idempotente : les pages d'un document sont remplacées en bloc.
    Un PDF scanné (< ~50 car./page) n'est pas indexé et porte `document.needsOCR`.
- **document_page_fts** — table virtuelle FTS5 synchronisée (déclencheurs GRDB)
  avec `document_page`, colonne indexée `content`, tokenizer `unicode61` avec
  `remove_diacritics 2` : la recherche « Verité » retrouve « vérité ». Classement
  par `bm25`, extraits par `snippet`.

## Migration v3 — surlignements ancrés (M2a)

Additive, après v2. Le **surlignement** est un acte persistant de l'utilisateur —
à ne pas confondre avec la **mise en surbrillance**, éphémère (voir Vocabulaire,
`../docs/10-ARCHITECTURE.md`).

- **annotation** — un passage surligné, éventuellement annoté.
  - `id`, `documentId` → `document(id)` (`ON DELETE CASCADE`, indexé).
  - **Ancrage PAR LE TEXTE** (décision d'Aubin, 18/07) : `quote` (la citation
    exacte) fait foi ; `prefix` / `suffix` conservent le contexte pour départager
    les occurrences. `pageNumber` (PDF) et `cfi` (EPUB) ne sont que des *indices
    de résolution* — jamais de géométrie seule, si bien que le surlignement
    survit au remplacement du fichier par une autre édition numérisée.
  - `note` (libre), `color` (nom de couleur, nul = défaut).
  - `projectId` : **réservé** aux couches d'annotations par Projet (50-HORIZON) —
    nul en v1, la colonne existe dès la première migration pour éviter une
    migration de confort plus tard.
  - `dateCreated`, `dateModified`.
- La résolution vit dans `AnnotationAnchor` (pur, testé) : elle cherche la
  citation dans `document_page` — repli de casse et de diacritiques — et rend
  `found` (à la page attendue), `moved` (le texte a bougé : le surlignement
  suit) ou `lost` (passage introuvable : jamais placé au hasard). Un scan muet
  doit donc être OCRisé avant d'être surligné.

## Conversations du démon (v4)

L'historique des échanges. On enregistre **ce qui a été montré**, jamais les
appels d'outils bruts ni les jetons propres à un fournisseur — la signature de
pensée que Gemini 3 attache à ses appels, par exemple. Ces jetons sont opaques,
périssables et liés à un fournisseur : les stocker interdirait d'ouvrir un fil
avec un modèle distant et de le poursuivre avec un modèle local.

- **conversation** — un fil.
  - `id`, `title` (nul tant que rien n'a été dit ; `ConversationTitle` le dérive
    de la première question, tronqué sur une frontière de mot).
  - `dateCreated`, `dateModified` (indexée) : c'est `dateModified` qui ordonne
    l'historique, si bien que rouvrir un vieux fil le ramène en tête.
- **conversation_message** — un message tel qu'affiché.
  - `id`, `conversationId` → `conversation(id)` (`ON DELETE CASCADE`).
  - `position` : rang dans le fil, calculé par le magasin — l'appelant ne compte
    jamais lui-même.
  - `role` : `user`, `assistant` ou `tool` (la fine ligne grise d'un outil).
  - `content`, `citationsJSON` (puces vérifiées déjà sérialisées, nul si la
    réponse n'en portait aucune — le moteur ne les interprète pas).
  - Index `(conversationId, position)` : la relecture d'un fil est le seul accès
    chaud.
- `ConversationStore.purgeEmpty()` balaie les fils ouverts puis abandonnés sans
  un mot : sans ce ménage, chaque « nouvelle conversation » laisserait une
  coquille dans l'historique.

## Migration v5 — Projets et Encres (Lot B)

Additive, après v4.

- **project** — un espace de travail.
  - `id`, `name` (non nul), `notes` (libre), `dateCreated`, `dateModified` (indexée).
- **project_item** — l'appartenance d'un document à un projet.
  - `projectId` → `project(id)` (`ON DELETE CASCADE`).
  - `documentId` → `document(id)` (`ON DELETE CASCADE`).
  - `dateAdded`.
  - Index `UNIQUE` sur `(projectId, documentId)`.
- **link** — l'encre, une relation colorée entre deux passages que le chercheur a marqués.
  - `id`, `kind` (texte : le type de relation), `color` (nom de couleur, nul = défaut).
  - `projectId` (nullable, reste global si nil).
  - `sourceAnnotationId` → `annotation(id)` (`ON DELETE CASCADE`), `targetAnnotationId` → `annotation(id)` (`ON DELETE CASCADE`).
  - `note`, `dateCreated`, `dateModified`.

**Note sur l'intégrité** : La colonne `projectId` existait déjà dans `annotation` (créée en v3). Nous n'avons PAS reconstruit la table `annotation` pour lui ajouter une contrainte de clé étrangère vers `project(id)`. SQLite ne sait pas ajouter une contrainte à une colonne existante sans reconstruire la table (ce qui n'est pas une migration purement additive). La colonne reste un `TEXT` simple. L'intégrité référentielle est garantie par le `ProjectStore` : supprimer un projet déclenche manuellement une mise à nul des `projectId` portés par les annotations et les encres, pour qu'elles retombent dans la couche globale sans jamais être perdues.

## Migration v6 — Persistance des documents introuvables (Lot I01)

Additive, après v5.

- **document.isMissing** — `BOOLEAN NOT NULL DEFAULT 0`.
  - Décision utilisateur : un document introuvable reste au catalogue avec son travail intellectuel (fiches, surlignements, liens et projets conservés).
  - Aucune suppression automatique lors d'une absence physique ou d'un scan incomplet.
  - La colonne `isMissing` passe à `true` lorsque le fichier n'est plus vu lors d'un scan complet fiable, et repasse à `false` dès sa réapparition ou son déplacement non ambigu.

## Migration v7 — Clés de citation (lot F2)

Additive, après v6.

- **edition_key** — la clé de citation d'une édition (`Adorno1951Minima`).
  - `editionId` → `edition(id)` (clé primaire, `ON DELETE CASCADE`).
  - `key` : `UNIQUE`, comparée **sans égard à la casse** (`COLLATE NOCASE`).
  - `origin` : `generated` (calculée, encore révisable), `stable` (déjà utilisée
    hors du catalogue) ou `manual` (saisie par l'utilisateur).
  - `dateAssigned`.
- Forme générée (`CiteKeyGenerator`) : nom de famille du premier auteur,
  année de l'œuvre (`work.date`, à défaut `edition.year`, sinon `ND`),
  premier mot significatif du titre — translittérés en ASCII, capitalisés.
  Collision : suffixe `-<année d'édition>` si elle diffère de celle de
  l'œuvre, sinon `-b`, `-c`…
- **Une clé stable ou manuelle ne change plus d'elle-même.** L'ingestion
  attribue une clé générée à chaque édition nouvelle ; tant qu'elle n'a pas
  été utilisée hors du catalogue, une correction peut la recalculer.
  `stabilizeKeys` fige les clés exportées ou copiées (Zotero, sites, BibTeX,
  liens de lecture). Seule une correction explicite de la clé la remplace
  (`origin = manual`). Une fusion refuse d'effacer la clé stable ou manuelle
  de l'édition absorbée.

Le fichier voisin `embeddings.sqlite` est un **index régénérable**, distinct du
format d'échange ci-dessus. Chaque passage vectorisé conserve désormais
`contentDigest`, empreinte du texte : un passage modifié est supprimé de
l'index puis réindexé, même si document et numéro de page restent identiques.
Une restauration du catalogue vide cet index. Aucune migration supplémentaire
du catalogue n'est introduite par cette consolidation (v8 conservée).

## Migration v8 — Liens d'autorité (lot F, 24/09)

Table `authority_link` (clé : `entityType`, `entityId`, `scheme`,
`identifier`) :

- `entityType` : `creator` | `work` ; `entityId` : l'identifiant de la fiche.
- `scheme` : `idref` (PPN) | `bnf` (`ark:/12148/…`) | `viaf` | `isni` |
  `wikidata` (`Q…`).
- `label` : la forme autorisée (« Adorno, Theodor Wiesengrund (1903-1969) »).
- `status` : `proposed` (trouvé, à valider) | `confirmed` (validé, ou prouvé
  par un livre possédé) | `rejected` (écarté, ne plus reproposer). Un lien
  n'est jamais rétrogradé par une machine.
- `evidence` : la preuve, en clair (« auteur de « Minima moralia » dans le
  Sudoc »).

Deux fiches d'auteur reliées à la même notice sont une seule personne
(`CatalogStore.sharedAuthorities`) ; `renameCreator` les fusionne.

**Clés (révision du 24/09)** : l'année de la base est celle de l'œuvre
(`work.date`), sinon celle de l'édition ; une année antique s'écrit sans
signe (`Aristote350Traite`). Deux œuvres différentes de même base prennent
chacune le mot de titre qui les distingue (`Rosenberg2007WilfridFusing`,
`Tolstoy1877AnnaII`) ; les éditions d'une même œuvre se départagent par
l'année d'édition (`-2003`), puis `-b`. `ishtar keys --recalculer` refait
toutes les clés provisoires ; les clés figées et manuelles ne bougent jamais.

## Catalogue publié — format d'échange (lot F3)

`ishtar publish` écrit, dans un dossier choisi par l'utilisateur, un
instantané lisible sans Ishtar :

- `catalogue.json` — le manifeste, écrit **en dernier** (un lecteur ne voit
  jamais un manifeste qui annonce des fichiers absents) :
  ```
  { "version": 1, "generatedAt": "<ISO 8601>", "library": "<nom du dossier>",
    "fonds": { "id": "aj", "nom": "aj" }?,
    "editions": [ { "key", "title", "subtitle"?, "authors": [..],
                    "year"?, "editionYear"?, "publisher"?, "language"?,
                    "isbn13"?, "doi"?, "discipline"?, "collections": [..],
                    "status", "confidence", "dateAdded",
                    "files": [ { "sha256", "path", "format", "size" } ] } ] }
  ```
  `path` est **relatif** à la racine de la bibliothèque. `year` est l'année
  de l'œuvre ; `editionYear` n'apparaît que si elle en diffère. `fonds`
  (facultatif, `--fonds`) dit de qui vient la bibliothèque : un site qui
  réunit plusieurs publications peut ainsi montrer chaque fonds à part.
- `covers/<sha256>.png` — les vignettes d'Ishtar, par empreinte de fichier.
- `catalog.sqlite` — copie de ce schéma **réduite aux documents publiés**
  (textes extraits compris) ; les conversations du démon en sont retirées.
- `corpus/` (avec `--corpus`, la face cachée pour les modèles, 25/09) :
  `<sha256>.pages.deflate` (texte extrait, DEFLATE brut, pages séparées par
  U+000C) et `annotations.json` — `{ annotations: [{ id, sha256, page?, cfi?,
  citation, avant?, apres?, note?, couleur?, date }], encres: [{ de, vers,
  nature?, note?, couleur? }] }`, triés, seulement pour les documents publiés
  (une encre dont un bout n'est pas publié ne sort pas). Jamais servi par
  Rayons ; le Bibliothécaire le réserve au droit Portier
  `bibliothecaire:annotations`.

Ne sont jamais publiés : les documents introuvables ou ignorés, ceux sans
empreinte, ceux hors de la racine, et ce qu'excluent les règles de
l'utilisateur (`--exclude <dossier>`, `--exclude-title-prefix <préfixe>`).
Une même empreinte n'est publiée qu'une fois.
