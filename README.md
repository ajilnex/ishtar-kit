# ishtar-kit

**FR** — Le moteur open source d'Ishtar, bibliothèque savante locale-first pour chercheurs en SHS : un dossier de documents devient un catalogue SQLite, scanné sans jamais être modifié, dédupliqué, identifié par un entonnoir mécanique, cherchable, publiable, interrogeable par un démon aux citations vérifiées.

**EN** — The open-source engine of Ishtar, a local-first scholarly library for humanities researchers.

## Modules

- `IshtarCatalog` : ontologie Œuvre/Édition/Document, schéma SQLite, migrations, curation
- `IshtarIngest` : scan, entonnoir, texte, OCR local, connecteurs opt-in, imports BibTeX/Zotero
- `IshtarSearch` : plein texte (FTS5), sémantique, publication, exports bibliographiques
- `IshtarDaemon` : clients LLM, outils, citations vérifiées
- `CSQLiteVec` : sqlite-vec
- `ishtar` : la CLI (`ishtar --help`)

## Invariants

1. Le scan et l'ingestion ne touchent jamais le réseau ni l'IA.
2. Le dossier de l'utilisateur n'est jamais modifié, sauf par `ranger`, `doublons` et `corriger` (`--appliquer`, journal pour défaire).
3. Une copie identique (même empreinte) à un document déjà catalogué rejoint son édition, marquée doublon : l'ingestion ne crée jamais une seconde fiche pour un même contenu.
4. Toute proposition d'identification est *proposée*, jamais imposée.
5. Le schéma SQLite est un format d'échange documenté ([SCHEMA.md](SCHEMA.md)).

## Clés de citation

Une clé se compose du nom de famille du premier auteur, de l'année de l'œuvre et du premier mot significatif du titre (`Adorno1951Minima`). Quand l'auteur est une collectivité, la clé prend son sigle, fait des initiales de ses mots significatifs (`AFD2024Economie` pour l'Agence française de développement, `OCDE`, `BM`) : la forme de classement d'une notice, quand elle est un mot seul (« AFD », « BnF »), prime toujours. La collectivité se reconnaît à un premier mot d'une liste courte (Agence, Institut, Université, Banque, Fondation, Comité…), ou au type de sa notice d'autorité quand l'appelant le donne. La règle ne vaut que pour les clés à créer : les clés existantes, figées ou manuelles ne bougent pas (`ishtar auteurs` avec `tri`, puis `ishtar cles`, pour en corriger une).

## Développement

```sh
swift build
Scripts/swift-test.sh   # `swift test` échoue sans Xcode
swift run ishtar scan <dossier>
```

macOS 14+, Swift 6 ; tests hors bac à sable (OCR Vision). Linux : `ishtar` seul, `Scripts/linux/construire.sh`.

## Publier

Le contrôle de `ranger` compare les auteurs de l'ancien nom avec tous les auteurs
de la notice, y compris les listes de noms inversés séparés par des virgules.
Une mention d'éditeur séparée n'est écartée que si elle correspond exactement
à l'éditeur enregistré. Un coauteur inconnu reste un conflit : le renommage
est retenu pour vérification. Le plan à blanc permet de contrôler ce résultat.

`ishtar publish --db catalog.sqlite --root <bibliothèque> --out <dossier>` écrit le « Catalogue publié » : `catalogue.json` (en dernier), `covers/`, et `corpus/` avec `--corpus`. `--exclude` (un nom vaut à toute profondeur) et `--exclude-title-prefix` fixent ce qui ne sort jamais ; `--dry-run` n'écrit rien. Format : SCHEMA.md ; contrat v1 : `contrats/` (dépôt `_PONTS`).

`ishtar corriger` retrouve un fichier par son nom quelle que soit sa forme Unicode (NFC ou NFD, celle du disque sous macOS).

`ishtar fusionner --db catalog.sqlite --cle <ancienne> --dans <gardée> [--preuve "…"] [--appliquer]` fusionne une édition (même à clé figée) dans une autre : ses documents passent à la gardée avec leurs annotations, ses auteurs, notes et collections sont reportés, l'ancienne clé devient une pierre (`fusionnée`) qui renvoie à la gardée — `publish` la rend dans `formerKeys`. Sans `--appliquer` : essai à blanc. Avec : Ishtar fermée, `ecriture.verrou` posé puis levé, une seule transaction, annulée si une annotation était perdue. La garde d'écriture ignore `launchd` et `UserEventAgent` : les veilleurs launchd (`WatchPaths`) ne tiennent le catalogue que pour le surveiller et ne bloquent pas.

Licence [Apache-2.0](LICENSE).
