# Qualité des pinceaux : état des lieux et plan

Comparaison faite à partir de trois sources :
- les vidéos de Paul (Minke dans Procreate et dans ProRange Creator, même geste) ;
- le fichier `Minke.brush` et l'Atelier de Procreate ;
- le manuel de Procreate (Atelier de pinceaux : mélange humide, dynamique de couleur, Apple Pencil, forme, stabilisation).

Le moteur de Procreate n'est pas documenté : le manuel décrit les effets, pas les calculs. Ce qui suit décrit ce qu'on
observe et ce qu'on fait pour l'égaler.

## Les technologies citées, et où on en est

| Technologie (Procreate) | Ce que c'est vraiment | ProRange Creator |
|---|---|---|
| **Moteur Valkyrie sur Metal** | Rendu GPU écrit pour les puces Apple | Pareil : moteur Metal maison (`BrushEngine`), chaque kernel vérifié contre une référence CPU |
| **120 images/s** | Écrans ProMotion uniquement | L'iPad Air 5 est à 60 Hz : 120 est demandé, 60 est le maximum de l'écran |
| **Latence réduite** | Coalescence des mesures du Pencil (240 Hz) et anticipation par touches prédites | Les deux. **Anticipation** : le trait est prolongé jusqu'où UIKit prévoit le Pencil, montré une image, puis remplacé par le vrai trait, environ 16 ms de retard en moins. Désactivée avec la stabilisation, comme il se doit |
| **Forme et grain** | Empreinte répétée le long du trait, fusionnée à une texture | Forme et grain, mipmaps, grain fixé ou mobile, rouleau, 8 modes de fusion, pinceau double |
| **Pression** | Taille, opacité, flux, bavure, avec courbes | Tout, avec courbes par réglage |
| **Inclinaison** | Opacité, dégradé, bavure, taille, au-delà d'un seuil | Tout. La rondeur selon l'inclinaison (forme couchée) ne marche qu'avec une forme importée |
| **Azimut** | La forme tourne avec la direction du Pencil | Fait (« La forme suit l'azimut ») ; chaque copie de symétrie a le sien |
| **StreamLine et stabilisation** | Lissage, moyenne mobile, filtrage des tremblements | Déjà là (StreamLine, stabilisation, filtrage du mouvement, lissage de la pression) ; le tracé suit en plus une courbe lisse |
| **Mélange humide (shaders)** | Dilution, charge, attaque, tirage, grade, flou | **Calculé** depuis le 2 novembre : le pinceau prend la couleur de la toile, se vide, se dilue (voir `WetMixer`) |
| **Dynamique de couleur** | Variation par tampon et par trait, pression, inclinaison, couleur secondaire | **Faite** ; couleur secondaire dans le panneau Couleur (toucher l'échange) |

## Ce qui fait la qualité d'un trait Procreate

| Facteur | Procreate (observé) | ProRange Creator avant | Maintenant |
|---|---|---|---|
| **Tracé** | Courbe lisse entre les mesures du Pencil, même en geste rapide | Segments droits entre mesures : polygones visibles en geste rapide | Courbe de Catmull-Rom centripète (`SplineStrokeSampler`) |
| **Pression** | Épaisseur continue | Pression constante sur chaque segment : marches d'épaisseur | Pression, inclinaison et azimut interpolés dab par dab |
| **Précision du Pencil** | Position au sous-point | `location` (arrondie au point d'écran) | `preciseLocation` |
| **Latence** | Trait collé à la mine | Une image de retard au moins | Anticipation par touches prédites |
| **Textures** | « Filtrage amélioré » : forme et grain filtrés selon la taille du tampon | Images de 500 texels lues à pleine résolution sur des tampons de 20 px : bords hérissés, grain moucheté | Mipmaps CPU + GPU, lecture trilinéaire (format r16Float filtrable partout) |
| **Accumulation** | Glacis : le trait ne fonce pas sur lui-même ; flux | Chaque tampon s'ajoutait | Masque de trait, glacis, flux, pinceau double ; couleur par texel pour les pinceaux à couleur variable |
| **Effilement** | Début et fin (la fin apparaît au lever) | Début seulement | Fin aussi : le trait est repeint au lever (`StackCanvas.replaceStroke`) |
| **Traits très fins** | Continus | Tampons plus petits qu'un texel : pointillés, scintillement | Rayon minimal 0,7 texel, opacité réduite d'autant (même quantité de peinture) |
| **Réglages** | ~150 réglages par pinceau | ~40 | ~120 (rendu, double, courbes, grain, variations, couleur, humide, Pencil…) |

## Minke, réglage par réglage

Les 240 clés de `Minke.brush` (principal et secondaire `Sub01`) ont été décodées et comparées à l'import. Écarts trouvés
et corrigés le 2 novembre :

| Réglage Procreate | Valeur | Avant | Maintenant |
|---|---|---|---|
| Rendu > Mode de fusion | Multiplier (`blendMode` 1) | Ignoré : Minke couvrait comme en Normal | Mode Multiplier : la peinture fonce celle déjà posée |
| Mélange humide | Dilution 0, charge 1 %, attaque 20 %, tirage 10 %, grade 80 % | Mélange actif : opacité ~44 %, trait vidé en quelques diamètres | Inactif sans dilution, comme Procreate |
| Pencil > Rondeur (pression, inclinaison) | Effet 100 %, minimum 100 % | Forme écrasée à pression légère | Aucun écrasement |
| Secondaire > Forme inversée | Oui | Ignoré | Appliqué à l'import (`Shape.png`) |

Formes et grains de Minke sont internes à Procreate : ils ne sont pas dans le dépôt, Paul les ajoute depuis ses PNG.
Encore non gérés (effet jugé nul ou inconnu) : `dynamicsPressure…Speed`, `maxPressureSizeClamped`, `textureZoom`,
`shapeFilterMode`, `legacyNormalDual`, bavure de 0,05 %.

## Ce qui reste différent

- **Définition de la toile** : Procreate peint à la résolution de l'écran ou plus. Une toile 4K (4096 × 2048) étalée sur
  360° donne environ 11 texels par degré ; à 90° de champ, l'écran de l'iPad (2360 px) agrandit chaque texel environ
  2,3 fois : un trait fin paraît flou de près. Une toile 8K divise ce flou par deux (au prix de la mémoire et de la
  latence mesurées en phase 9). C'est le premier levier de netteté restant, à arbitrer avec Paul.
- **Valeurs exactes** : glacis, fusion du grain, mélange maximal, mélange humide et dynamique de couleur sont
  reconstitués d'après les vidéos et le manuel, pas copiés. Le mélange humide en particulier est à régler sur l'iPad.
- **Mélange humide** : la toile lue est celle d'avant le trait (le trait ne reprend pas sa propre peinture), et le flou
  est approché par la couleur moyenne d'une zone plus large, pas par un vrai flou de la toile.
- **Mémoire** : l'anticipation ajoute une copie du masque (64 Mo en 4K), la couleur par texel une ou deux (pinceaux à
  couleur variable seulement).
- **Pencil Pro** (roulis, pression latérale) : sans objet sur l'iPad Air 5.
