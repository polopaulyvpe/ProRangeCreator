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

| `BlendModeTests` | Valeurs connues des modes séparables ; comportement > 1 (bornés / non bornés) ; règles de luminosité des modes non séparables ; codes identiques au shader ; composition (Procreate, transparent, opacité nulle) ; Normal = pinceau ; verrou alpha |
| `PaintingTests` | Courbe prolongée au-delà de 1 (continuité, réversibilité) ; gris moyen façon Procreate ; fusions d'accord sur fond vide et opaque ; gomme ; dynamique de pression ; HSB et hexadécimal |
| `ViewStateTests` | Direction regardée selon yaw et tangage ; bords du champ ; vue dépliée = équirectangulaire ; hors panorama ; extrémités du morphing ; dépliage et repliage centrés ; six faces ; bornes et sens des gestes |

## Suites actuelles (PREngine) — sautées sans GPU

| Suite | Vérifie |
|---|---|
| `PanoramaRendererTests` | Compilation du shader ; vue dépliée identique à la texture au pixel près ; vue sphère conforme aux directions CPU, couture comprise (moins de 2 % d'écarts d'un texel aux frontières) ; valeurs affichées dans [0, 1] pour les quatre courbes à +6 EV |
| `DisplayTextureTests` | Réduction 2×, calque brut sans fond |
| `BrushEngineTests` | Pinceau GPU contre référence CPU (fusion perceptuelle et linéaire, pôle, couture, HDR, gomme) |
| `StackCanvasTests` | **Shader contre compositeur CPU pour les 26 modes × 2 espaces** (chemin GPU) ; chemin CPU (Produit au-dessus, masque) ; peinture du masque ; trait GPU annulé sans trace, validé identique au calque CPU, annulé par l'historique ; verrou alpha GPU = CPU |

## Suites actuelles (PRImaging)

| Suite | Vérifie |
|---|---|
| `ExportTests` | Aller-retour EXR pour toutes les variantes (half ou float, aucune ou ZIP, avec ou sans alpha, dernier bloc incomplet), exact ; ZIP plus de 2× plus petit sur un dégradé ; **relecture par ImageIO** des EXR (toutes variantes) et du Radiance ; aller-retour Radiance (pixels bruts et RLE) dans la précision RGBE ; RLE ; zlib, Adler-32 et prédicteur ; export d'un calque identique à la source, en 2 bandes, sans fichier temporaire restant ; HDR à plus de 45 dB de PSNR ; export réduit et transparent ; annulation sans fichier |

## Suites actuelles (PRStorage)

| Suite | Vérifie |
|---|---|
| `TiledLayerTests` | Calque 16K vierge sans aucune tuile ; dab identique à la toile de référence (arrondi en demi-flottants) ; petit dab limité aux tuiles voisines ; dab au pôle (toute la rangée) et sur la couture ; remplissage uniforme et vidage ; recompression sans perte ; calque RGBA8 |
| `LayerStackTests` | Ajouter, déplacer, grouper, dégrouper, supprimer (dernier calque protégé) ; plafond de 50 et duplication indépendante ; annulation de structure ; modes et visibilité dans le composite ; écrêtage, masque, isolation des groupes ; fusion et aplatissement fidèles et annulables ; projet v2 aller-retour et lecture d'un v1 |
| `UndoRedoTests` | 12 opérations annulées puis rétablies, chaque étape identique octet par octet ; branche à rétablir effacée par une nouvelle opération ; opération vide non enregistrée ; plafond de pas |
| `ProjectPackageTests` | Sauvegarde (deux fois, avec remplacement) puis chargement exacts au bit près, métadonnées des calques comprises ; manifest manquant refusé |
| `OperationJournalTests` | Ajout, lecture par index, écriture après lecture en fin de fichier, relecture complète |
| `SpillTests` | Tuiles déversées relues à l'identique ; peindre dessus, annuler et rétablir restent exacts ; `unspillAll` ne laisse aucun fichier ; un calque déversé se sauvegarde normalement ; historique déversé exact au bit près ; fichiers d'historique supprimés avec les entrées |
| `MemoryBudgetManagerTests` | Mémoire suffisante : rien ne bouge ; pression critique : déversement sauf la zone de travail, contenu intact, conseil de fusion, purge ; mémoire inconnue : plafond résident et simple recompression |

## Mesures sur l'appareil

Les runners n'ont pas de GPU fiable, et la latence, la mémoire réelle et les fps ne se mesurent que sur l'iPad.
Paul installe le `.ipa` avec Sideloadly et relève les chiffres des écrans de spike.
Les profils Instruments demandés par le cahier des charges sont impossibles sans Mac. Ils sont remplacés par l'instrumentation intégrée à l'app (`os_signpost` + affichage des temps à l'écran).
