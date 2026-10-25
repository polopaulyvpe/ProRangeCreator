# Architecture

## Modules

| Module | Rôle | État |
|---|---|---|
| `PRCore` | Vecteurs, projections équirectangulaires, plan tangent, échantillonnage des traits, couleur, budget mémoire, rasteriseur CPU de référence | Spike phase 1 |
| `PRStorage` | Tuiles éparses, compression, déversement disque, format `.prorange`, journal d'opérations | Phase 1 |
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

## Pipeline de rendu, format de projet, journal

À définir en phases 1 et 2.
