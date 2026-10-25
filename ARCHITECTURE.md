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

- Le panorama du calque est mis en RGBA16F linéaire prémultiplié avec mipmaps, à partir des tuiles. Le **papier blanc est composé par le shader**, ce qui permet au pinceau GPU d'écrire directement dans cette texture. La pile de calques arrive en phase 4.
- La largeur est plafonnée à 8K (`maxWidth`) : une toile 16K est réduite par moyenne de blocs 2×2. Côté GPU, une toile 8K occupe environ 360 Mo avec ses mipmaps.
- Seules les tuiles modifiées sont renvoyées au GPU, et les mipmaps sont régénérées une fois par image si besoin.
- **Limite connue** : à 16K, l'affichage plafonne à 8K. Il manque encore une texture virtuelle par tuiles pour afficher le détail 16K au zoom maximum. C'est prévu avec la passe de performance, et il faudra le mesurer sur l'appareil.

## Peinture (phase 3)

### Fusion et couleur (PRCore)

- **D4** : par défaut, le mélange est **perceptuel** (`blendPerceptual`). La couleur de dessous est dé-prémultipliée, puis les deux couleurs sont encodées, mélangées en source-over et décodées ; le stockage reste linéaire prémultiplié. L'option `BlendSpace.linear` mélange en lumière linéaire.
- La courbe de transfert est **prolongée linéairement au-delà de 1** (pente 1,055 / 2,4) : elle reste continue et réversible pour les valeurs HDR.
- **Gomme** (`DabMode.erase`) : même forme et même moteur que le pinceau, avec `dst *= 1 − couverture × opacité`.
- **Pression** (`BrushSettings`) :
  - la taille varie de `minimumSize` à 1 (activé par défaut) ;
  - l'opacité peut aussi suivre la pression (désactivé par défaut) ;
  - le doigt compte comme une pression de 1 ;
  - l'espacement entre dabs suit le rayon courant.
- **Couleur** : `HSBColor` et `HexColor` travaillent sur les composantes encodées sRGB. La conversion en linéaire ne se fait qu'à la création du dab.

### Pinceau GPU (`BrushEngine`) et cycle d'un trait (`LayerCanvas`)

- **Kernel `stampDab`** : un dispatch par dab et par plage de colonnes de l'`EquirectSpan`, qui boucle sur la couture et prend les rangées entières aux pôles. Les dispatchs sont sérialisés dans l'ordre des dabs. Le calcul reproduit `DabEvaluator` et `SphericalRasterizer.apply`. Testé : à moins de 0,01 de la référence CPU, sur plus de 99,9 % des valeurs, dans les deux espaces de fusion.
- **Pendant le trait** : les dabs s'accumulent et sont peints à l'image suivante, dans la texture du calque. La latence est donc d'une image, sans prédiction pour l'instant.
- **Fin du trait** : on attend le GPU, on relit les tuiles touchées dans le calque CPU (`replaceTile`, enregistré), et on obtient les deltas de l'historique. Le calque CPU reste ainsi la source de vérité (sauvegarde, historique, déversement).
- **Trait annulé** (second doigt, pipette, geste d'historique) : on recopie les tuiles touchées depuis le calque CPU, qui n'a pas changé. Il ne reste aucune trace.
- **Repli CPU** si la texture n'est pas à pleine résolution (toile > 8K) ou si le calque est en 8 bits.

### Gestes (App)

| Geste | Action |
|---|---|
| 1 doigt ou Pencil | Peindre ou gommer (pression du Pencil) |
| Second doigt posé pendant un trait | Le trait commencé est annulé |
| Appui long 1 doigt (0,5 s) | Pipette (couleur affichée, composée sur le papier) |
| Pincer, glisser à 2 doigts, tourner | Navigation (phase 2) |
| Double tap 2 doigts | Annuler |
| Double tap 3 doigts | Rétablir |
| Maintien 2 doigts (0,6 s) | Annulation rapide continue |

## Export et fichiers (MVP)

### Codecs (PRImaging)

- **OpenEXR** (`EXRWriter` / `EXRReader`) :
  - image simple partie en lignes, version 2, lignes croissantes ;
  - canaux par ordre alphabétique : (A,) B, G, R, en half ou float ;
  - compression aucune (1 ligne par bloc) ou ZIP : blocs de 16 lignes, octets pairs puis impairs, différences +128, flux zlib (DEFLATE du framework Compression avec en-tête et Adler-32) ;
  - un bloc qui ne rapetisse pas est stocké brut, comme le prévoit OpenEXR ;
  - attributs requis écrits : `channels`, `compression`, `dataWindow`, `displayWindow`, `lineOrder`, `pixelAspectRatio`, `screenWindowCenter`, `screenWindowWidth` ;
  - PIZ n'est pas géré (D10).
- **Radiance** (`RadianceWriter` / `RadianceReader`) :
  - RGBE, en-tête `#?RADIANCE`, `FORMAT=32-bit_rle_rgbe`, orientation `-Y H +X W` ;
  - RLE « nouveau style » par canal pour des largeurs de 8 à 32 767 pixels, pixels bruts sinon.

### Export en flux (`PanoramaExporter`, `LayerRowSource`)

- Le calque est lu par **bandes de 256 lignes** (une rangée de tuiles), réduit par moyenne de blocs (1, 2, 4 ou 8), puis composé sur le papier blanc ou laissé transparent. L'image entière n'est jamais en mémoire : une bande fait 64 Mo à 16K.
- Le fichier est écrit à côté sous un nom temporaire (`.nom.partial`), puis renommé une fois complet. Annuler ou échouer le supprime.
- La progression est donnée par bande, et le rappel peut annuler l'export.
- Dans l'app, l'export tourne dans une tâche détachée. La feuille d'export est modale : personne ne peint pendant ce temps.
- Orientation (préréglages Blender, UE5, Unity), cubemap, PNG, TIFF et lot de résolutions : phase 7.

### Projets dans l'app

- `Documents/Projets/<nom>.prrange` (format `ProjectPackage`) et `Documents/Exports/`. Les deux sont visibles dans l'app Fichiers (`UIFileSharingEnabled`), et l'export propose aussi la feuille de partage.
- Ouvrir un projet remplace le calque, recrée sa texture GPU et vide l'historique. L'historique ne survit pas à la fermeture : c'est voulu pour le MVP.

## Calques (phase 4)

### Modes et composition (PRCore)

- **`BlendMode`** : les 26 modes, avec les formules séparables et non séparables (Lum, ClipColor, SetSat) du W3C Compositing Level 1. Les codes du shader suivent l'ordre de `allCases`, et un test vérifie qu'ils correspondent.
- **Valeurs > 1** :
  - modes **non bornés** (Normal, Produit, Obscurcir, Éclaircir, Densité linéaire +, Ajout, Soustraction, Division, Différence, Couleur plus foncée et plus claire) : les valeurs passent telles quelles. Le résultat est seulement borné à 0 et au-dessus, et la Division est plafonnée à 65 504 ;
  - modes **bornés** (tous les autres) : les deux couleurs sont écrêtées à [0, 1] avant le calcul.
- **`Compositing.composite`** : on calcule `Cs' = (1 − αb)·s + αb·B(b, s)`, puis un source-over prémultiplié, dans l'espace de fusion (D4). Le Normal perceptuel est identique au pinceau (testé).

### Pile (`LayerStack`, PRStorage)

- C'est une liste plate de `StackItem`, de bas en haut. Les enfants d'un groupe sont **juste sous lui**, contigus. Un `StackItem` est une valeur qui référence les `TiledLayer` : une copie de la liste fait donc un instantané de structure peu coûteux.
- Chaque élément a : opacité, visibilité, mode, **verrou alpha** (pour le pinceau), **écrêtage**, **masque** (un `TiledLayer`, canal rouge : blanc visible, noir caché ; créé blanc uniforme, donc presque gratuit) et groupe parent.
- Opérations :
  - ajouter au-dessus de l'élément actif, dupliquer, supprimer (un groupe emporte ses enfants, le dernier calque est refusé) ;
  - monter et descendre parmi les frères, avec les enfants ;
  - grouper avec l'élément de dessous, dégrouper, ajouter ou supprimer un masque ;
  - **fusionner vers le bas** (bake du mode, de l'opacité, du masque et de l'écrêtage dans le calque du dessous) et **aplatir**.
- **Plafond de 50 calques.** Le nombre **garanti** vient de `MemoryBudget` avec `os_proc_available_memory`, et le panneau le compare au nombre de calques.

### Historique de structure

- `HistoryEntry` porte des deltas de tuiles (un calque) **et/ou** un couple de structures (avant, après). La cible est `HistoryTarget`, c'est-à-dire la pile.
- Annuler restaure les pixels puis la structure ; rétablir fait l'inverse. Ainsi, une fusion annulée restaure le calque du dessous **et** fait réapparaître celui du dessus.
- Les changements de propriétés (mode, visibilité, verrou, écrêtage) sont des entrées de structure. Un glissé du curseur d'opacité donne **une seule** entrée.

### Compositeur CPU (`LayerCompositor`)

- Il compose une tuile à la fois. Pour chaque élément :
  - un groupe est composé à part, sur transparent, puis fondu avec son mode : pas de mode « transfert » pour l'instant ;
  - le masque multiplie l'alpha de la source ;
  - un élément écrêté est multiplié par l'alpha de la dernière base non écrêtée (masque compris, opacité non comprise) ; si la base est masquée, il l'est aussi.
- Une tuile vide d'un calque est sautée, ce qui garde le coût proportionnel à ce qui est peint.
- Ce compositeur sert à l'export, aux caches d'affichage, à la fusion, à la pipette et de référence pour tester le GPU.

### Affichage et peinture (`StackCanvas`, PREngine)

- **Chemin GPU** quand c'est exact : le calque actif est à la racine, sans masque ni écrêtage, et tout ce qui est visible au-dessus est en Normal.
  - Trois textures : *dessous* (papier + racine sous l'actif, composé CPU), *actif* (peint par le kernel du pinceau, verrou alpha compris) et *dessus* (composé sur transparent).
  - Le shader calcule `dessus ⊕Normal (actif ⊕mode,opacité dessous)`. C'est exact parce que le Normal est associatif dans notre représentation : chaque étape ré-encode la couleur droite.
  - Testé contre le compositeur CPU pour les **26 modes** et les deux espaces.
  - Changer l'opacité ou le mode du calque actif ne change qu'un uniforme ; changer de calque reconstruit les caches.
- **Chemin CPU** sinon (mode non Normal au-dessus, masque, écrêtage, groupe, peinture du masque, toile > 8K) : le pinceau CPU peint, et les tuiles touchées sont recomposées entièrement à chaque image dans la texture *dessous*. C'est exact, mais plus lent sur les gros traits.
- Mémoire GPU à 8K : trois textures RGBA16F avec mipmaps, soit environ 1,1 Go.

## Outils sphériques (phase 5)

Méthode validée au point de contrôle :
1. **Déformations** (rotation de la sphère, et plus tard transformation et liquify) par **mapping inverse** : chaque texel calcule sa direction, la ramène dans la source et y lit la valeur bilinéaire (longitude bouclée, latitude bornée). Chaque application coûte un rééchantillonnage.
2. **Outils locaux** (doigt, clonage) dans l'empreinte sphérique du dab, comme le pinceau.
3. **Propagation** (remplissage, sélection automatique) sur la grille, avec la couture et les pôles connectés.
4. **Formes** (symétries, dégradés, plus tard sélections et QuickShape) définies sur la sphère : plans miroirs, grands cercles, calottes.

### Lot A (fait)

- **Symétrie** (`SymmetrySettings`) : miroir gauche/droite (plan vertical contenant l'axe de la vue au moment de l'activation), miroir haut/bas (horizon), quadrants, radiale à n copies autour de la verticale, kaléidoscope. Chaque dab est dupliqué, pour le pinceau, la gomme et le doigt.
- **Guides** (shader) : grille de latitudes et longitudes tous les 10, 15, 30 ou 45°, horizon renforcé, lignes antialiasées d'un pixel quel que soit le zoom. Ils sont liés au repère du monde et ne tournent pas avec l'aperçu de rotation.
- **Rotation de la sphère** :
  - aperçu immédiat : le shader tourne la lecture (`contentRot`), pas les pixels ;
  - « Appliquer » fait tourner tous les calques et masques avec `WarpEngine` (kernel GPU, testé contre `TiledLayer.rotateContent`), en une seule entrée d'historique (`HistoryEntry.otherLayers`).
- **Remplissage** (`floodFill`) :
  - par segments horizontaux, sur la couleur encodée et l'alpha du calque cible, avec un seuil ;
  - bouclage sur la couture, passage par le pôle (même rangée, longitude opposée) ;
  - composé en Normal avec l'opacité du pinceau.
- **Dégradé** (`SphericalGradient`) : linéaire le long du grand cercle de A vers B, ou radial (angle depuis A). Il va de la couleur courante au transparent, et il est calculé en parallèle par rangée de tuiles.
- **Doigt** (`smudge`) : chaque texel du dab reçoit la couleur lue au point correspondant du dab précédent (rotation qui amène le centre précédent sur le centre courant), mélangée selon la force.
- **Clonage** (`clone`) :
  - une première touche définit la source ;
  - le trait recopie à travers la rotation qui amène son point de départ sur la source ;
  - la lecture se fait dans un instantané pris au début du trait.
- Le doigt et le clonage passent par le **chemin CPU** (`StackCanvas.forceCPU`, puis `edit`), car ils lisent les pixels pendant le trait.

### Lot B (fait)

- **Sélection** (`SelectionMask`) :
  - c'est un calque tuilé de valeurs dans [0, 1] : rien de sélectionné ne coûte rien, une tuile entièrement sélectionnée ne coûte qu'un pixel ;
  - ses changements s'enregistrent dans l'historique comme ceux d'un calque (`SessionHistoryTarget`).
- **Formes** (rectangle, ellipse, main levée) : tracées à l'écran en NDC, puis évaluées sur la sphère en projetant chaque direction dans la vue du tracé (`ProjectionParameters.ndc(of:)`, inverse exact de la projection). On sélectionne ce qu'on voit, quelle que soit la vue (sphère, fenêtre plane ou dépliée). Rien n'est sélectionné derrière la caméra.
- **Automatique** : propagation sur le calque cible, avec un seuil, la couture et les pôles (même code que le remplissage).
- **Combinaison** : remplacer, ajouter (max) ou retirer (min avec 1 − nouveau). Il y a aussi inverser, tout sélectionner, désélectionner.
- **Adoucir** : trois passes de flou boîte séparables. Le rayon horizontal vaut r / cos(latitude), pour que le rayon reste constant en angle sur la sphère.
- **Effet sur les outils** :
  - pinceau et gomme : la couverture du dab est multipliée par la sélection ;
  - doigt, clonage, remplissage, dégradé : l'opération est contrainte après coup, chaque pixel revenant vers son état d'avant en proportion de ce qui n'est pas sélectionné (`constrainCurrentOperation`) ;
  - avec une sélection, la peinture passe par le chemin CPU.
- **Affichage** : hors sélection, l'image est assombrie (texture de sélection à 4K au plus).
- **Transformer** (`SphericalTransform`) :
  - échelle (uniforme ou X/Y) et rotation dans le plan tangent au centre de la sélection, puis déplacement (rotation de la sphère vers le point sous le doigt) ;
  - aperçu du contenu flottant dans le shader, par la même transformation inverse ;
  - l'application se fait par mapping inverse : le contenu sélectionné est retiré, transformé et reposé par-dessus le reste, et la sélection suit ;
  - une seule entrée d'historique, pour le calque et la sélection ;
  - sans sélection, tout le calque est transformé ;
  - limite : pendant l'aperçu, le contenu reste aussi visible à sa place d'origine jusqu'à « Appliquer ».

### Lot C (fait)

- **Liquify** (`TiledLayer.liquify`) :
  - quatre modes : pousser (rotation qui ramène vers le dab précédent), tourbillon (rotation autour du centre), pincer et gonfler (échelle dans le plan tangent) ;
  - le déplacement est pondéré par la couverture du dab, dureté comprise : il s'annule au bord, sans couture ;
  - il lit l'état courant, donc les déformations s'accumulent le long du trait ;
  - chemin CPU, symétrie prise en compte ;
  - limite : tourbillon et pincement n'agissent que quand le doigt bouge, pas en continu à l'arrêt.
- **QuickShape** :
  - un trait de pinceau ou de gomme suivi d'un arrêt de 0,6 s est reconnu comme un **arc de grand cercle** (écart au grand cercle des extrémités inférieur à 12 % de la corde) ou un **petit cercle** (trait fermé, rayon constant à 24 % près) ;
  - le trait à main levée est alors annulé et la forme propre repeinte dans le même trait ;
  - pas d'ellipse ni de polygone pour l'instant, et la forme ne se modifie pas après coup.
- **Texte** :
  - rendu UIKit (police système grasse, couleur courante), puis converti en linéaire prémultiplié ;
  - posé par `placeImage` comme une photo tenue face à la direction regardée (projection rectiligne, largeur angulaire réglable), sur un **nouveau calque** ;
  - une seule entrée d'historique (structure + pixels) ;
  - le texte est rastérisé : il ne se modifie plus comme un texte.
  - `placeImage` servira aussi à l'import d'une image plate (mode B de la section 15, phase 7).
- **Distorsion** (`SphericalDistort`) :
  - quatre poignées sur le plan gnomonique au centre de la sélection ;
  - une **homographie** envoie le carré d'origine sur le quadrilatère tiré ;
  - c'est exact pour une rotation de la sphère, qui agit comme une homographie de ce plan ;
  - les droites (grands cercles) restent droites ;
  - aperçu dans le shader (homographie inverse) ; application par mapping inverse au contenu et à la sélection ;
  - limité à l'hémisphère avant de l'origine ;
  - **pas de déformation par grille** (warp à mailles) : non faite dans ce lot.
- Transformation et distorsion partagent `TiledLayer.applyWarp` et `SelectionMask.warp`.
