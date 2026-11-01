# Qualité des pinceaux : état des lieux et plan

Comparaison faite à partir des vidéos de Paul (Minke dans Procreate et dans ProRange Creator, même geste), du fichier
`Minke.brush` et de l'Atelier de Procreate. Le moteur de Procreate n'est pas documenté : ce qui suit décrit ce qu'on
observe, et ce qu'on fait pour l'égaler.

## Ce qui fait la qualité d'un trait Procreate

| Facteur | Procreate (observé) | ProRange Creator avant | Maintenant |
|---|---|---|---|
| **Tracé** | Courbe lisse entre les mesures du Pencil, même en geste rapide | Segments droits entre mesures : polygones visibles en geste rapide | Courbe de Catmull-Rom centripète (`SplineStrokeSampler`) |
| **Pression** | Épaisseur continue | Pression constante sur chaque segment : marches d'épaisseur | Pression et inclinaison interpolées dab par dab |
| **Précision du Pencil** | Position au sous-point | `location` (arrondie au point d'écran) | `preciseLocation` |
| **Textures** | « Filtrage amélioré » : forme et grain filtrés selon la taille du tampon | Images de 500 texels lues à pleine résolution sur des tampons de 20 px : bords hérissés, grain moucheté | Mipmaps CPU + GPU, lecture trilinéaire (format r16Float filtrable partout) |
| **Accumulation** | Glacis : le trait ne fonce pas sur lui-même ; flux | Chaque tampon s'ajoutait | Masque de trait, glacis, flux, pinceau double |
| **Effilement** | Début et fin (la fin apparaît au lever) | Début seulement | Fin aussi : le trait est repeint au lever (`StackCanvas.replaceStroke`) |
| **Traits très fins** | Continus | Tampons plus petits qu'un texel : pointillés, scintillement | Rayon minimal 0,7 texel, opacité réduite d'autant (même quantité de peinture) |
| **Réglages** | ~150 réglages par pinceau | ~40 | ~90 (rendu, double, courbes, grain en rouleau, fusion du grain, variations…) |

## Ce qui reste différent

- **Définition de la toile** : Procreate peint à la résolution de l'écran ou plus. Une toile 4K (4096 × 2048) étalée sur
  360° donne environ 11 texels par degré ; à 90° de champ, l'écran de l'iPad (2360 px) agrandit chaque texel environ
  2,3 fois : un trait fin paraît flou de près. Une toile 8K divise ce flou par deux (au prix de la mémoire et de la
  latence mesurées en phase 9). C'est le premier levier de netteté restant, à arbitrer avec Paul.
- **Mélange humide** : réglages lus et gardés, effet pas encore calculé.
- **Dynamique de couleur** : pas encore implémentée.
- **Valeurs exactes** : le moteur de Procreate n'étant pas publié, les formules (glacis, fusion du grain, mélange
  maximal) sont reconstituées d'après les vidéos, pas copiées.
