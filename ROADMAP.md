# Feuille de route

| Phase | Contenu | État |
|---|---|---|
| 0 | Cadrage, squelette, CI, docs (D1, D7, D8) | ✅ fait, CI à valider au premier push |
| 1 | Spike : projection et pinceau sphérique (CPU), mesure mémoire 16K | 🟡 code écrit, en attente de CI et de mesures sur l'iPad |
| 1 | Fondations : tuiles éparses, format de projet, journal (D2, D3) | ⏳ |
| 2 | Visualisation : sphère, dépliage, fenêtre plane, LOD, tone mapping (D5, D12) | ⏳ |
| 3 | Cœur de peinture Metal, latence du stylet, gomme, couleur, annulation (D4, D6) | ⏳ |
| — | **MVP** = phases 0 à 3 + export EXR/HDR simple | ⏳ |
| 4 | Calques, modes de fusion, masques, budget mémoire | ⏳ |
| 5 | Outils sphériques | ⏳ |
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
