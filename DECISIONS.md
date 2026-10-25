# Journal des décisions

| # | Date | Décision | Raison | Alternative écartée |
|---|---|---|---|---|
| — | 2026-10-25 | Build par **GitHub Actions** (runner macOS), dépôt **public** ; installation par `.ipa` non signé + Sideloadly | Pas de Mac. Les minutes macOS sont gratuites sans limite pratique en public, et Claude lit les erreurs lui-même avec `gh` | Mac loué dans le cloud (payant), Swift Playgrounds (boucle lente, pas de XCTest), app web WebGPU (16K irréaliste, latence) |
| — | 2026-10-25 | Pas de Swift pour Windows en local | Évite une installation lourde ; tous les tests tournent sur la CI | Toolchain locale pour les tests de PRCore |
| D1 | 2026-10-25 | **Natif Swift 6 + Metal 3**, UIKit pour la toile, SwiftUI pour les panneaux | Recommandation du cahier des charges, compatible avec la compilation sur CI | React + WebGPU + Capacitor |
| D7 | 2026-10-25 | **iPadOS 17+** ; appareil de référence iPad Air 5 (M1, 8 Go, SDR, Pencil 2) | Recommandé ; l'iPad de Paul le supporte | iPadOS 18+ |
| D8 | 2026-10-25 | Nom **ProRange Creator**, bundle `com.paulpenal.prorangecreator`, préfixe de modules `PR` | Choix de Paul (le cahier des charges proposait « Zenith ») | Zenith |

## Conséquences de l'iPad Air 5

- **Pas d'écran XDR** : pas de vrai affichage HDR. Les valeurs > 1 sont stockées et exportées, mais à l'écran on les voit par écrêtage ou tone mapping avec exposition. Le code EDR reste prévu, désactivé.
- **8 Go de RAM** : 16K possible avec très peu de calques pleins. Proposition : 8K par défaut à la création d'un projet. À trancher au checkpoint de la phase 1 avec les mesures réelles.
- **Pencil 2** : pas de survol, de roll ni de squeeze. Gardés dans l'architecture, inactifs.
