# ishtar-kit

**FR** — Le moteur open source d'[Ishtar](https://ishtar.app), bibliothèque savante locale-first pour chercheurs en sciences humaines et sociales. Un dossier chaotique de documents devient un catalogue : scanné sans jamais être modifié, dédupliqué par contenu, identifié par un entonnoir mécanique (nom de fichier → métadonnées embarquées → ISBN/DOI et catalogues publics), cherchable — et, dans l'application, interrogeable par un démon dont les citations sont vérifiées contre vos documents réels.

**EN** — The open-source engine of Ishtar, a local-first scholarly library for humanities researchers. A messy folder of documents becomes a catalog: scanned without ever being modified, content-deduplicated, identified through a mechanical funnel, searchable — and, in the app, queryable by a daemon whose citations are verified against your actual documents.

## Modules

| Module | Rôle |
|---|---|
| `IshtarCatalog` | Ontologie Œuvre / Édition / Document (FRBR-léger), schéma SQLite (GRDB), migrations |
| `IshtarIngest` | Scan non destructif, SHA-256, entonnoir d'identification, dossiers → collections |
| `IshtarSearch` | Recherche de catalogue (FTS5 plein texte et sémantique aux jalons suivants) |
| `IshtarDaemon` | Contrats du démon : contexte d'invocation, flux d'événements, fournisseurs BYOK/locaux, registre d'outils |
| `ishtar` (CLI) | `ishtar scan <dossier>`, `ishtar ingest <dossier> --db <catalogue.sqlite>` |

## Invariants

1. Le scan ne touche jamais le réseau ni l'IA.
2. Le dossier de l'utilisateur est en **lecture seule**.
3. Toute proposition d'identification est *proposée*, jamais imposée.
4. Le schéma SQLite est un format d'échange documenté ([SCHEMA.md](SCHEMA.md)).

## Développement

```sh
swift build
swift test
swift run ishtar scan ~/Documents/MaBibliotheque
```

Requiert macOS 14+, Swift 6. Licence [Apache-2.0](LICENSE).
