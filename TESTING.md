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
| `SphereToolsTests` | Symétries (nombre de copies, reflets, latitude conservée en radiale, axe qui suit la vue) ; paramètre des dégradés linéaire et radial ; rotation minimale entre deux directions |
| `SelectionShapeTests` | Rectangle, ellipse, polygone ; modes de combinaison ; projection inverse exacte (rectiligne, fenêtre plane, dépliée près de la couture), rien derrière la caméra ; transformation sphérique (origine → cible, inverse, échelle angulaire) |
| `DeformationTests` | Gnomonique aller-retour ; homographie par quatre coins (coins, inverse, identité, cas dégénéré) ; distorsion (identité, décalage, hémisphère opposé) ; QuickShape (ligne tremblée, cercle, gribouillis refusé) |
| `PaintingTests` | Courbe prolongée au-delà de 1 (continuité, réversibilité) ; gris moyen façon Procreate ; fusions d'accord sur fond vide et opaque ; gomme ; dynamique de pression ; HSB et hexadécimal |
| `AdjustmentTests` | Courbe identité, monotone, passant par ses points, prolongée en HDR ; ajustements neutres, désaturation, inversion, dégradé, recoloration (hors tolérance intacte), teinte HDR, balance ; bruit sphérique déterministe, continu sur la couture, uniforme |
| `BrushTipTests` | Échantillonnage bilinéaire (centres de texels, répétition) ; forme sur la sphère (côtés, coins du carré, hors carré), demi-tour ; grain (profondeur, continuité sur la couture) ; réglages → pointe et angle du trait |
| `PreferencesTests` | Aller-retour JSON ; champ inconnu, manquant ou illisible sans perte des autres ; courbe de pression (linéaire, ferme, douce, bornes) |
| `BuiltInBrushesTests` | Catalogue complet (catégories, identifiants uniques), textures ni vides ni pleines et dans [0, 1] ; tampon soleil (cœur, halo) et silhouette de collines (pleine en bas, vide en haut) sur la sphère |
| `ViewStateTests` | Direction regardée selon yaw et tangage ; bords du champ ; vue dépliée = équirectangulaire ; hors panorama ; extrémités du morphing ; dépliage et repliage centrés ; six faces ; bornes et sens des gestes |

## Suites actuelles (PREngine) — sautées sans GPU

| Suite | Vérifie |
|---|---|
| `PanoramaRendererTests` | Compilation du shader ; vue dépliée identique à la texture au pixel près ; vue sphère conforme aux directions CPU, couture comprise (moins de 2 % d'écarts d'un texel aux frontières) ; valeurs affichées dans [0, 1] pour les quatre courbes à +6 EV |
| `SelectionDisplayTests` | Hors sélection assombri dans le shader ; aperçu du contenu flottant déplacé |
| `WarpAndGuidesTests` | Rotation GPU contre référence CPU, puis annulation exacte ; guides (horizon tracé, rien entre les lignes) ; aperçu de rotation dans le shader |
| `DisplayTextureTests` | Réduction 2×, calque brut sans fond |
| `BrushEngineTests` | Pinceau GPU contre référence CPU (fusion perceptuelle et linéaire, pôle, couture, HDR, gomme) |
| `FilterEngineTests` | **Les ajustements GPU contre `Adjustment.apply`** ; flou, bruit et aberration chromatique GPU contre CPU ; flou de mouvement et netteté laissent un aplat intact ; bloom (rien sous le seuil, halo autour du HDR) ; aperçu en direct dans la toile, annulé sans trace puis appliqué |
| `BrushTipGPUTests` | **Forme tournée et grain triplanaire : kernel GPU contre `DabEvaluator`** (équateur, couture, pôle, HDR) |
| `StackCanvasTests` | **Shader contre compositeur CPU pour les 26 modes × 2 espaces** (chemin GPU) ; chemin CPU (Produit au-dessus, masque) ; peinture du masque ; trait GPU annulé sans trace, validé identique au calque CPU, annulé par l'historique ; verrou alpha GPU = CPU |

## Suites actuelles (PRImaging)

| Suite | Vérifie |
|---|---|
| `ExportTests` | Aller-retour EXR pour toutes les variantes (half ou float, aucune ou ZIP, avec ou sans alpha, dernier bloc incomplet), exact ; ZIP plus de 2× plus petit sur un dégradé ; **relecture par ImageIO** des EXR (toutes variantes) et du Radiance ; aller-retour Radiance (pixels bruts et RLE) dans la précision RGBE ; RLE ; zlib, Adler-32 et prédicteur ; export d'un calque identique à la source, en 2 bandes, sans fichier temporaire restant ; HDR à plus de 45 dB de PSNR ; export réduit et transparent ; annulation sans fichier |

| `FullExportTests` | **PNG 8/16, TIFF 16/32 et JPG relus par ImageIO** (valeurs exactes à l'arrondi près, HDR conservé en TIFF) ; orientation (lacet = décalage exact, miroir) ; cubemap : aller-retour face/direction, centre de chaque face, croix et bande ; lot de résolutions ; annulation sans fichier pour PNG, TIFF, JPG ; courbes de tone mapping |
| `ImportTests` | Décodage PNG (linéaire), EXR (notre lecteur et ImageIO avec alpha corrigé), HDR ; panorama identique à même taille, réduction, lacet ; recadrage et marges d'une image carrée ; **aller-retour équirect → cubemap → équirect** (> 30 dB) ; croix découpée = six faces ; ordre de la bande ; détection des dispositions |

| `BrushAndTimelapseTests` | Faux `.brush` (ZIP stocké et deflate, archive NSKeyedArchiver) : nom, opacité, espacement, rotation, grain, pression repris, clé inconnue signalée, forme lue ; `.brushset` à deux pinceaux ; `.prbrush` aller-retour ; PNG → forme et grain inversé ; **timelapse** : captures, export HEVC déplié et sphère (codec et durée vérifiés par AVFoundation), copie et rechargement avec le projet |

## Suites actuelles (PRStorage)

| Suite | Vérifie |
|---|---|
| `TiledLayerTests` | Calque 16K vierge sans aucune tuile ; dab identique à la toile de référence (arrondi en demi-flottants) ; petit dab limité aux tuiles voisines ; dab au pôle (toute la rangée) et sur la couture ; remplissage uniforme et vidage ; recompression sans perte ; calque RGBA8 |
| `LayerStackTests` | Ajouter, déplacer, grouper, dégrouper, supprimer (dernier calque protégé) ; plafond de 50 et duplication indépendante ; annulation de structure ; modes et visibilité dans le composite ; écrêtage, masque, isolation des groupes ; fusion et aplatissement fidèles et annulables ; projet v2 aller-retour et lecture d'un v1 |
| `DeformationToolTests` | Liquify pousser (le contenu avance), tourbillon, pincer et gonfler (centre fixe) ; pose d'une image face à une direction ; distorsion qui déplace le contenu |
| `SelectionMaskTests` | Sélections par formes depuis deux vues, ajout, retrait, inversion, effacement ; adoucissement ; sélection automatique ; pinceau limité à la sélection ; contrainte d'une opération ; transformation du contenu et de la sélection ; copie masquée |
| `SpatialToolTests` | Remplissage dans un anneau, à travers la couture et le pôle, seuil ; dégradé radial ; clonage par rotation ; doigt qui traîne la couleur ; rotation CPU ; entrée d'historique multi-calques |
| `FilterReferenceTests` | Ajustement limité aux tuiles peintes et journalisé ; **flou séparable contre vrai flou sphérique** ; aplat conservé par le flou ; bruit (transparent intact, grain, monochrome) |
| `ProjectLibraryTests` | Noms nettoyés et numérotés ; duplication et renommage avec leurs instantanés ; dossiers d'instantanés hors de la liste des projets ; suppression complète ; un instantané garde son contenu quand le projet est réenregistré |
| `UndoRedoTests` | 12 opérations annulées puis rétablies, chaque étape identique octet par octet ; branche à rétablir effacée par une nouvelle opération ; opération vide non enregistrée ; plafond de pas |
| `ProjectPackageTests` | Sauvegarde (deux fois, avec remplacement) puis chargement exacts au bit près, métadonnées des calques comprises ; manifest manquant refusé |
| `OperationJournalTests` | Ajout, lecture par index, écriture après lecture en fin de fichier, relecture complète |
| `SpillTests` | Tuiles déversées relues à l'identique ; peindre dessus, annuler et rétablir restent exacts ; `unspillAll` ne laisse aucun fichier ; un calque déversé se sauvegarde normalement ; historique déversé exact au bit près ; fichiers d'historique supprimés avec les entrées |
| `MemoryBudgetManagerTests` | Mémoire suffisante : rien ne bouge ; pression critique : déversement sauf la zone de travail, contenu intact, conseil de fusion, purge ; mémoire inconnue : plafond résident et simple recompression |

## Mesures sur l'appareil

Les runners n'ont pas de GPU fiable, et la latence, la mémoire réelle et les fps ne se mesurent que sur l'iPad.
Paul installe le `.ipa` avec Sideloadly et relève les chiffres des écrans de spike.
Les profils Instruments demandés par le cahier des charges sont impossibles sans Mac. Ils sont remplacés par l'instrumentation intégrée à l'app (`os_signpost` + affichage des temps à l'écran).
