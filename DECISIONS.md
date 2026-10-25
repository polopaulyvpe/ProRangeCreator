# Journal des décisions

| # | Date | Décision | Raison | Alternative écartée |
|---|---|---|---|---|
| — | 2026-10-25 | Build par **GitHub Actions** (runner macOS), dépôt **public** ; installation par `.ipa` non signé + Sideloadly | Pas de Mac. Les minutes macOS sont gratuites sans limite pratique en public, et Claude lit les erreurs lui-même avec `gh` | Mac loué dans le cloud (payant), Swift Playgrounds (boucle lente, pas de XCTest), app web WebGPU (16K irréaliste, latence) |
| — | 2026-10-25 | Pas de Swift pour Windows en local | Évite une installation lourde ; tous les tests tournent sur la CI | Toolchain locale pour les tests de PRCore |
| D1 | 2026-10-25 | **Natif Swift 6 + Metal 3**, UIKit pour la toile, SwiftUI pour les panneaux | Recommandation du cahier des charges, compatible avec la compilation sur CI | React + WebGPU + Capacitor |
| D7 | 2026-10-25 | **iPadOS 17+** ; appareil de référence iPad Air 5 (M1, 8 Go, SDR, Pencil 2) | Recommandé ; l'iPad de Paul le supporte | iPadOS 18+ |
| D8 | 2026-10-25 | Nom **ProRange Creator**, bundle `com.paulpenal.prorangecreator`, préfixe de modules `PR` | Choix de Paul (le cahier des charges proposait « Zenith ») | Zenith |
| D2 | 2026-10-25 | Tuiles de **256²** (`TileSize.side`) | Recommandation appliquée sans mesure sur l'appareil (installation bloquée). Deltas d'annulation 4× plus petits (512 Ko par tuile en RGBA16F contre 2 Mo), stockage épars plus fin autour des petits traits. Une constante à changer si les mesures Metal le justifient | 512² (choix initial de l'autre session) |
| D3 | 2026-10-25 | **RGBA16F linéaire prémultiplié** par défaut ; **RGBA8 sRGB prémultiplié** en option par calque | Recommandé : HDR natif ; le 8 bits divise la mémoire par deux mais écrête à [0, 1] | RGBA32F (2× la mémoire du 16F sans gain visible) |
| D5 | 2026-10-25 | **Trois vues** : sphère immersive (défaut), dépliée à plat avec morphing (~0,6 s), fenêtre plane (6 faces en raccourci) | Choix de Paul, conforme au cahier des charges | Sphère + dépliée seulement |
| D12 | 2026-10-25 | Affichage par défaut : **écrêtage simple** ; tone mapping AgX / ACES / filmique en option, avec exposition | Choix de Paul ; les couleurs ≤ 1 s'affichent comme dans Procreate, et l'écran de l'iPad Air 5 n'est pas HDR | AgX ou ACES par défaut |
| D4 | 2026-10-25 | Fusion **perceptuelle façon Procreate** par défaut : mélange sur les valeurs encodées sRGB, stockage linéaire prémultiplié, courbe prolongée linéairement au-delà de 1 ; option « lumière linéaire » | Choix de Paul : mêmes résultats visuels que Procreate | Lumière linéaire par défaut |
| D6 | 2026-10-25 | Double tap 2 doigts = annuler ; double tap 3 doigts = rétablir ; maintien 2 doigts (0,6 s) = annulation rapide continue (toutes les 0,12 s) | Choix de Paul, conforme au cahier des charges | Sans maintien |
| — | 2026-10-25 | Pinceau sur GPU dans la texture du calque, puis relecture des tuiles touchées dans le calque CPU en fin de trait | Latence d'une image ; l'historique reste exact (il enregistre ce que le GPU a produit) ; repli CPU si la texture n'est pas à pleine résolution (toile > 8K) | Pinceau CPU + envoi des tuiles (plus lent) |
| — | 2026-10-25 | Toile de l'écran de travail : 8K par défaut | Le pinceau GPU travaille dans une texture pleine résolution (256 Mo à 8K, 1 Gio à 16K) ; 16K attendra la texture virtuelle | 16K |
| — | 2026-10-25 | Annulation par **deltas de tuiles compressés** (`UndoRedoManager`), pas par rejeu du journal | Exigé par le cahier des charges (§14) ; exact au bit près, coût indépendant de la longueur de l'historique. Le journal binaire des opérations est gardé pour le timelapse | Checkpoints + rejeu (commit 48c3ee9 d'une autre session : ne restaurait pas les pixels) |

## Conséquences de l'iPad Air 5

- **Pas d'écran XDR** : pas de vrai affichage HDR. Les valeurs > 1 sont stockées et exportées, mais à l'écran on les voit par écrêtage ou tone mapping avec exposition. Le code EDR reste prévu, désactivé.
- **8 Go de RAM** : 16K possible avec très peu de calques pleins. Proposition : 8K par défaut à la création d'un projet. À trancher au checkpoint de la phase 1 avec les mesures réelles.
- **Pencil 2** : pas de survol, de roll ni de squeeze. Gardés dans l'architecture, inactifs.
