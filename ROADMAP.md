# Feuille de route

| Phase | Contenu | État |
|---|---|---|
| 0 | Cadrage, squelette, CI, docs (D1, D7, D8) | ✅ fait, CI verte |
| 1 | Spike : projection et pinceau sphérique (CPU), mesure mémoire 16K | 🟡 15 tests verts sur CI, mesures sur l’iPad en attente |
| 1 | Fondations : tuiles éparses, format de projet, journal, déversement disque, budget mémoire (D2, D3) | ✅ CI verte ; mesures mémoire sur l'iPad en attente (installation bloquée côté Apple) |
| 2 | Visualisation : sphère, dépliage, fenêtre plane, LOD, tone mapping (D5, D12) | 🟡 code et tests poussés ; reste à valider sur l'iPad (fluidité, gestes). Limite : affichage plafonné à 8K, pas encore de texture virtuelle pour le détail 16K. EDR non applicable (écran SDR) |
| 3 | Cœur de peinture Metal, latence du stylet, gomme, couleur, annulation (D4, D6) | 🟡 code et 56 tests verts (GPU contre CPU sur le runner) ; reste à mesurer sur l’iPad la latence du trait (cible ≤ 16 ms) et à valider la sensation ; pas encore de prédiction des touches |
| — | **MVP** = phases 0 à 3 + export EXR/HDR simple | 🟡 code complet, 66 tests verts (relecture ImageIO comprise) ; reste la validation sur l’iPad (installation bloquée côté Apple) |
| 4 | Calques, modes de fusion, masques, budget mémoire | 🟡 pile 50 calques, 26 modes, masques, groupes, écrêtage, verrou alpha, fusion, aplatissement, projet v2 ; shader contre CPU testé pour les 26 modes ; reste la validation sur l’iPad (fluidité du chemin CPU, mémoire des 3 textures) |
| 5 | Outils sphériques | 🟡 lot A fait (rotation de la sphère, symétrie, guides, remplissage, dégradés, doigt, clonage) ; lots B (sélections, transformation) et C (liquify, QuickShape, texte, déformation) à faire |
| 6 | Ajustements et filtres | ⏳ |
| 7 | Import/export complet, import de pinceaux (D9, D10) | ⏳ |
| 8 | HDR et lumière (D11) | ⏳ |
| 9 | Bibliothèque, galerie, préférences, finitions | ⏳ |

## Démo du spike (à faire par Paul sur l'iPad)

1. Onglet **Pinceau** :
   - Toucher **Grille de test**. Les tampons s'étirent à plat vers les pôles : c'est voulu, ils sont ronds sur la sphère. Ceux de la couture (bords gauche et droit) se raccordent sans coupure.
   - Peindre en travers de la couture et autour du haut de l'image.
   - Activer **Empreinte écran** pour comparer avec un pinceau naïf, qui serait déformé sur la sphère.
2. Onglet **Mémoire** :
   - Noter la mémoire disponible.
   - Ajouter des calques 16K RGBA16F jusqu'à l'échec ou la fermeture de l'app, et noter la dernière ligne.
   - Recommencer en 8K.
