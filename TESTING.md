# Tests

## Où ça tourne

Tout tourne sur **GitHub Actions** (`.github/workflows/build.yml`), à chaque push sur `main` :

1. `swift test --parallel` dans `Packages/ProRangeKit` (macOS) ;
2. génération du projet avec XcodeGen, compilation iPadOS non signée, puis publication du `.ipa` comme artefact (gardé 14 jours).

```bash
gh run watch
gh run view --log-failed
```

## Suites actuelles (PRCore)

| Suite | Vérifie |
|---|---|
| `ProjectionTests` | Directions connues ; aller-retour pixel ↔ direction (pôles, couture, coins) ; aller-retour lat/lon ; plan tangent équidistant ; nord local ; espacement des dabs sur la sphère ; courbe sRGB |
| `SphericalBrushTests` | Empreinte bornée = parcours complet ; aire = calotte à 1,5 % près ; rondeur dans 16 secteurs à un texel près ; dureté |
| `MemoryBudgetTests` | Tailles des calques pleins (2K à 16K) ; calques garantis pour 5 Gio disponibles |

## Suites actuelles (PRStorage)

| Suite | Vérifie |
|---|---|
| `TiledLayerTests` | Calque 16K vierge sans aucune tuile ; dab identique à la toile de référence (arrondi en demi-flottants) ; petit dab limité aux tuiles voisines ; dab au pôle (toute la rangée) et sur la couture ; remplissage uniforme et vidage ; recompression sans perte ; calque RGBA8 |
| `UndoRedoTests` | 12 opérations annulées puis rétablies, chaque étape identique octet par octet ; branche à rétablir effacée par une nouvelle opération ; opération vide non enregistrée ; plafond de pas |
| `ProjectPackageTests` | Sauvegarde (deux fois, avec remplacement) puis chargement exacts au bit près, métadonnées des calques comprises ; manifest manquant refusé |
| `OperationJournalTests` | Ajout, lecture par index, écriture après lecture en fin de fichier, relecture complète |

## Mesures sur l'appareil

Les runners n'ont pas de GPU fiable, et la latence, la mémoire réelle et les fps ne se mesurent que sur l'iPad.
Paul installe le `.ipa` avec Sideloadly et relève les chiffres des écrans de spike.
Les profils Instruments demandés par le cahier des charges sont impossibles sans Mac. Ils sont remplacés par l'instrumentation intégrée à l'app (`os_signpost` + affichage des temps à l'écran).
