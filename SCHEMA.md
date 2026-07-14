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
- Migrations à venir (M2–M3) : annotations ancrées, liens typés, artéfacts,
  embeddings (sqlite-vec, dimension par modèle), conversations du démon.

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
