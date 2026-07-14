# ishtar-kit — consignes agent

Moteur open source (Apache-2.0) d'Ishtar, bibliothèque savante locale-first pour
les SHS. Le cockpit du projet est dans `../docs/` (dépôt ishtar-docs) : lire
`10-ARCHITECTURE.md` (invariants) et son WP dans `30-CHANTIERS.md` avant de coder.

Règles dures :
- Le scan ne touche jamais le réseau ni l'IA ; les dossiers scannés sont en
  lecture seule absolue.
- Ce paquet ne dépend jamais de SwiftUI/AppKit d'interface : testable sans UI.
- Migrations GRDB additives uniquement ; schéma documenté dans SCHEMA.md.
- La correction humaine est le seul chemin vers la confiance `high`.
- Tout changement livre ses tests : `swift test` doit être vert.
- Commentaires en français, sobres (contraintes, pas de narration).

Épreuve du réel (lecture seule) : `swift run ishtar scan ~/SARx/Bibliothèque\ céleste`
