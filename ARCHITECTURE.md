# Architecture

## Modules

| Module | Rôle | État |
|---|---|---|
| `PRCore` | Vecteurs, projections équirectangulaires, plan tangent, échantillonnage des traits, couleur, budget mémoire, rasteriseur CPU de référence | Spike phase 1 |
| `PRStorage` | Calques en tuiles éparses, compression LZFSE, historique par deltas, paquet `.prrange`, journal d'opérations | Phase 1 (déversement disque à venir) |
| `PREngine` | Metal : pinceau, composition, filtres, sondes mémoire | Sonde mémoire seulement |
| `PRImaging` | Codecs EXR / HDR / PNG / TIFF, cubemap, export en flux | Phase 7 |
| `PRUI` | Composants SwiftUI partagés | Phase 3 |
| `App` | Cible iPad | Écrans de spike |

Dépendances : `PRCore` ← `PRStorage`, `PRImaging` ← `PREngine` ← `PRUI` ← `App`. `PRCore` ne dépend de rien d'autre que `simd`.

## Conventions sphériques

- Direction `d = (x, y, z)` unitaire, **Y vers le haut**, la vue par défaut regarde vers **-Z**.
- Équirectangulaire : `u = atan2(x, -z) / 2π + 0.5`, `v = acos(y) / π`.
  - `v = 0` au zénith, `v = 1` au nadir ; `u = 0.5` face à -Z, `u = 0.75` vers +X ; la couture est à `u = 0 ≡ 1` (direction +Z).
  - Centre du texel `(x, y)` : `u = (x + 0.5) / W`, `v = (y + 0.5) / H`.
- Latitude `= asin(y)`, longitude `= atan2(x, -z)` ∈ [-π, π].
- Testé : aller-retour pixel → direction → pixel aux pôles, à la couture et aux coins (`ProjectionTests`).

## Pinceau sphérique sans distorsion

1. La taille du pinceau est un **rayon angulaire** r (radians).
2. Le trait est échantillonné **sur la sphère** : les centres des dabs sont espacés d'un angle constant le long des grands cercles (slerp), voir `SphericalStrokeSampler`.
3. Pour chaque dab, la zone touchée (`EquirectSpan`) est la bande de latitude `lat ± r` et, en longitude, `±asin(sin r / cos lat)`. Si la calotte englobe un pôle, on prend les rangées entières. Les colonnes bouclent sur la couture (une ou deux plages).
4. Chaque texel de cette zone est projeté dans le **plan tangent** au point d'impact (`TangentFrame`, projection azimutale équidistante). La distance au centre y est exactement l'angle sur la sphère, et l'axe y suit le nord local. La forme et le grain du pinceau s'échantillonnent dans ce plan : un disque y est un cercle sur la sphère, quelle que soit la latitude.
5. Bord antialiasé sur ±½ texel angulaire (π/H).

Validé par `SphericalBrushTests` :
- l'empreinte bornée est identique au parcours de toute la toile, aux pôles et sur la couture ;
- l'aire peinte pondérée par l'angle solide correspond à la calotte, à 1,5 % près ;
- le rayon atteint est le même dans 16 secteurs d'azimut, à un texel près.

Le kernel Metal (phase 3) reprendra exactement ce calcul, et sera testé contre `SphericalRasterizer`.

## Mémoire

- Calque plein à 16K : RGBA8 = 512 Mio, RGBA16F = 1 Gio, RGBA32F = 2 Gio.
- `MemoryBudget.guaranteedLayers` donne le pire cas : tous les calques pleins et résidents, plus 3 équivalents-calques de travail (cache dessous, cache dessus, tampon de trait) et 400 Mio de réserve.
- L'écran « Mémoire » du spike mesure `os_proc_available_memory` sur l'appareil et alloue de vraies textures Metal jusqu'à l'échec.

## Stockage (PRStorage)

### Calques tuilés (`TiledLayer`)

- Tuiles de 256² (D2, `TileSize.side`), coordonnées `TileCoord(level, x, y)` ; `level` 0 = résolution de travail, les niveaux suivants serviront au LOD.
- Format par calque (D3) : `rgba16Float` (demi-flottants linéaires prémultipliés, 8 o/px) ou `rgba8` (sRGB prémultiplié, 4 o/px, écrêté à [0, 1]).
- Chaque tuile est dans l'un de ces états :
  - absente : jamais peinte ou revenue à transparent, elle n'occupe rien ;
  - uniforme : un seul pixel brut ;
  - pixels : décompressée, en cours de travail ;
  - compressée : LZFSE en mémoire.
- `putPixels` normalise automatiquement : une tuile uniforme est réduite à un pixel, une tuile transparente est supprimée. `compact(keeping:)` recompresse les tuiles hors de la zone de travail.
- Le pinceau (`stamp`) calcule d'abord la couverture du dab sur chaque tuile de l'`EquirectSpan` : une tuile que le dab ne touche pas n'est ni créée ni enregistrée. Il applique ensuite le même `DabEvaluator` que la toile CPU de référence. Testé : résultat identique à la référence, arrondi en demi-flottants.

### Historique (`UndoRedoManager`)

- `perform(name, on: layer) { … }` encadre une opération : `beginOperation` mémorise l'état d'avant (`TileState`) de chaque tuile au premier contact, `endOperation` produit les `TileDelta` (avant/après) des seules tuiles réellement changées.
- Annuler applique les états « avant », rétablir les états « après » : c'est exact au bit près, sans rejouer de trait.
- Plafond par défaut de 1 000 pas. Une nouvelle opération efface la branche à rétablir. Le débordement sur disque viendra avec le gestionnaire de budget mémoire.

### Paquet de projet `.prrange`

```
Projet.prrange/
  manifest.json                         version, largeur, hauteur, taille de tuile, espace couleur, calques (id, nom, format, opacité, visibilité)
  layers/{uuid}/tiles/0/{x}_{y}.tile.lzfse   pixels bruts du format du calque, compressés
  layers/{uuid}/tiles/0/{x}_{y}.uniform      un pixel brut
  journal.bin                            journal binaire des opérations (timelapse)
```

- La sauvegarde écrit dans un dossier temporaire voisin, puis remplace l'ancien paquet d'un coup. Le journal est conservé.
- Le chargement vérifie la version et la taille de tuile, et décompresse chaque tuile une fois pour la valider.

### Journal d'opérations (`OperationJournal`)

Fichier binaire en ajout seul, de la forme `[tag][longueur][JSON]` (trait, gomme, remplissage, transformation, marqueur). Il sert au timelapse et à l'inspection, pas à l'annulation.

## Pipeline de rendu

À définir en phase 2.
