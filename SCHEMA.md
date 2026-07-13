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
- Migrations à venir (M1–M3) : pages extraites + FTS5, annotations ancrées, liens typés,
  artéfacts, embeddings (sqlite-vec, dimension par modèle), conversations du démon.
