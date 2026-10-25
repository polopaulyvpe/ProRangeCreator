# ProRange Creator — instructions pour Claude Code

App iPad native (Swift 6 + Metal) pour peindre des HDRI équirectangulaires 2:1, « Procreate pour les HDRI ».
Cahier des charges complet : [docs/CAHIER-DES-CHARGES.md](docs/CAHIER-DES-CHARGES.md) (écrit sous le nom de travail « Zenith »).
Usage personnel de Paul, aucune publication. Aucune IA générative dans l'app. Ne rien copier de Procreate (nom, icônes, assets).

## Contraintes matérielles (décisives)

- **Pas de Mac.** Le développement se fait sous Windows. Rien ne compile en local : ni Swift, ni Xcode, ni Metal.
- **Toute compilation et tous les tests passent par GitHub Actions** (runner `macos-15`, `.github/workflows/build.yml`).
  Boucle : commit → push → `gh run watch` → en cas d'échec `gh run view --log-failed` → corriger → recommencer.
- Le projet Xcode est **généré** par XcodeGen depuis `project.yml` sur la CI. Ne jamais versionner de `.xcodeproj`.
- Appareil cible : **iPad Air 5** (M1, 8 Go, écran SDR non XDR, Apple Pencil 2 : pression, inclinaison, double tap ;
  pas de survol, de roll ni de squeeze). Installation du `.ipa` non signé par Paul via Sideloadly (Apple ID gratuit, 7 jours).
- Le runner `macos-15` a un GPU Metal utilisable : les tests de rendu tournent et comparent le GPU à la référence CPU.
  Ils restent écrits pour se sauter proprement (`XCTSkip`) sans GPU. Les mesures réelles (latence, mémoire, fps) sont faites
  par Paul sur l'iPad.
- Écrire du code Swift 6 qui compile du premier coup autant que possible : concurrence stricte, `@MainActor` pour l'UI,
  types `Sendable` dans PRCore. Relire chaque fichier avant de pousser : un aller-retour CI coûte 5 à 10 minutes.

## Commandes

```bash
gh run list --limit 5                 # derniers builds
gh run watch                          # suivre le build en cours
gh run view --log-failed              # logs des étapes en échec
gh run download --name ProRangeCreator-ipa   # récupérer le .ipa
```

## Structure

- `App/` — cible iPad (SwiftUI + UIKit). Pour l'instant : écrans de spike.
- `Packages/ProRangeKit/` — `PRCore` (maths, projections, couleur, rasteriseur CPU de référence), `PRImaging` (codecs),
  `PRStorage` (tuiles, projet, journal), `PREngine` (Metal), `PRUI` (composants SwiftUI).
- `docs/` — cahier des charges.

## Conventions

- Projection : voir ARCHITECTURE.md. Angles en **radians** dans le code, degrés seulement dans l'UI.
- Couleur de travail : RGB **linéaire prémultiplié** ; conversion sRGB/P3 uniquement à l'entrée (sélecteur) et à l'affichage.
- Tout kernel GPU a une **implémentation de référence CPU** dans PRCore, et un test qui compare les deux.
- Toute modification de pixels passe par une opération journalisée (à partir de la phase 1).
- Commentaires et docs en français. Noms de code en anglais.
- Chaque phase se termine par : CI verte, démo décrite, mise à jour de ARCHITECTURE / DECISIONS / ROADMAP / TESTING, checkpoint avec Paul
  (AskUserQuestion, 4 questions max, option recommandée en premier). Sans réponse : appliquer la recommandation et la noter dans DECISIONS.md.
