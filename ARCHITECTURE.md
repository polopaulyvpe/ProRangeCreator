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
- Plafond par défaut de 1 000 pas. Une nouvelle opération efface la branche à rétablir.
- `spill(keepingRecent:)` écrit sur disque les entrées éloignées de l'état courant, en encodage binaire des deltas. Annuler ou rétablir les relit au besoin, et leurs fichiers sont supprimés quand les entrées disparaissent.

### Déversement et budget mémoire (`MemoryBudgetManager`)

- Une tuile peut être **déversée** : compressée dans le `spillStore` du calque, elle n'occupe plus rien en mémoire. La lecture et l'écriture la rechargent de façon transparente, et l'écriture supprime son fichier.
- La pression se lit sur `os_proc_available_memory` sous iPadOS ; ailleurs, sur un plafond de mémoire résidente :

  | Pression | Seuil par défaut | Action |
  |---|---|---|
  | normale | plus de 1 Gio disponible | aucune |
  | élevée | moins de 1 Gio | recompression en mémoire des tuiles hors zone de travail |
  | critique | moins de 512 Mio | déversement des tuiles inactives de tous les calques et de l'historique ancien (20 entrées gardées autour de l'état courant) |

- Si la pression reste critique après ces actions, `MemoryReport.suggestMergingLayers` le signale, et l'interface doit avertir et proposer de fusionner des calques. On ne plante jamais en silence.
- Les tuiles de la zone de travail du calque actif ne sont jamais déversées.
- Une tuile déversée illisible arrête l'app avec un message explicite, plutôt que de laisser peindre sur des pixels perdus.
- L'app devra appeler `relieve` régulièrement et sur l'avertissement mémoire du système. Ce branchement arrive avec le moteur, en phases 2 et 3.

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

## Vues et rendu (phase 2)

### Vues (`ViewState`, PRCore)

- **Sphère** :
  - caméra au centre ; `yaw` vaut 0 vers -Z et grandit vers +X ; `pitch` est positif vers le haut, borné à ±89,9° ; `roll` n'agit que si l'horizon est déverrouillé ;
  - le champ de vision est vertical, de 20° à 150° ;
  - rotation caméra → monde : `Ry(-yaw) · Rx(pitch) · Rz(roll)`.
- **Dépliée** :
  - `unfoldedCenter` est l'uv équirectangulaire au centre de l'écran ; `unfoldedSpan` est la hauteur visible en v (1 = tout le panorama) ;
  - comme le panorama est 2:1, une unité de u occupe deux fois plus de pixels qu'une unité de v ;
  - le centre boucle sur la couture.
- **Fenêtre plane** : vue rectiligne verrouillée sur une des six faces (`CubeFace`), avec zoom et décalage du point principal (`flatShift`).
- **Dépliage** :
  - le morphing mélange les deux projections inverses : `normalize(mix(direction rectiligne, direction dépliée, t))`, avec t animé de 0 à 1 en 0,6 s (courbe smoothstep) ;
  - `prepareUnfold` centre la vue à plat sur la direction regardée, `prepareFold` fait regarder la caméra le centre de la vue à plat.
- `ProjectionParameters.direction(ndc:)` sert de référence CPU au shader : mêmes formules, en double précision. Il sert aussi au pinceau pour convertir un point de l'écran en direction.

### Rendu (`PanoramaRenderer`, PREngine)

- Les shaders MSL sont compilés au lancement (`makeLibrary(source:)`). On dessine un seul triangle qui couvre l'écran, et le fragment calcule la direction de chaque pixel.
- Échantillonnage :
  - u boucle (`repeat`), v est bloqué aux bords ;
  - le **niveau de mipmap est calculé explicitement** à partir de la taille angulaire d'un pixel comparée à celle d'un texel. Il n'y a donc pas de saut de dérivées sur la couture.
- Couleur : on multiplie par 2^exposition, puis on applique la courbe : **écrêtage par défaut (D12)**, ou AgX, ACES (Narkowicz) ou filmique (Hable). L'écran utilise `bgra8Unorm_srgb`, le matériel encode donc le sRGB.
- La vue Metal tourne à 120 images/s en continu. Le dessin à la demande viendra avec la passe de performance.

### Texture d'affichage et LOD (`DisplayTexture`)

- Le panorama est mis en RGBA16F avec mipmaps, à partir des tuiles du calque, en composite sur le fond blanc. La pile de calques arrive en phase 4.
- La largeur est plafonnée à 8K (`maxWidth`) : une toile 16K est réduite par moyenne de blocs 2×2. Côté GPU, une toile 8K occupe environ 360 Mo avec ses mipmaps.
- Seules les tuiles modifiées sont renvoyées au GPU, et les mipmaps sont régénérées une fois par image si besoin.
- **Limite connue** : à 16K, l'affichage plafonne à 8K. Il manque encore une texture virtuelle par tuiles pour afficher le détail 16K au zoom maximum. C'est prévu avec la passe de performance, et il faudra le mesurer sur l'appareil.
