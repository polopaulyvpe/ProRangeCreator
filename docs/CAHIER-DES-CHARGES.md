# Prompt Claude Code — « Zenith » : peinture de HDRI sur iPad (« Procreate pour les HDRI »)

> Nom de travail : **Zenith** (renommable, voir décision D8). Usage : personnel (un seul utilisateur, pas de publication prévue).

---

## 0. Méthode de travail (à lire en premier)

Tu es Claude Code. Tu construis cette application **par phases** (section 19). Règles de fonctionnement :

1. **Je (Paul) veux pouvoir choisir pendant la construction.** À chaque checkpoint de phase, utilise l'outil de questions (AskUserQuestion), **4 questions maximum par appel**, avec l'option recommandée en premier et marquée « (Recommandé) ». Les décisions D1 à D12 (section 19) sont listées pour ça.
2. **Je suis pressé.** Si je ne réponds pas ou réponds « je ne sais pas », applique l'option recommandée, note-la dans `DECISIONS.md` (date, choix, raison, alternative écartée) et continue sans bloquer.
3. **Commence par un spike risqué avant de coder le reste** : les points les plus dangereux sont (a) la peinture sans distorsion sur sphère, (b) la mémoire à 16K, (c) la latence du stylet. Valide-les en premier, par de petits prototypes mesurés.
4. Tiens à jour `CLAUDE.md` (contraintes et conventions du projet), `ARCHITECTURE.md`, `DECISIONS.md` et `ROADMAP.md`. Chaque phase se termine par : build qui passe, tests verts, courte démo décrite, mise à jour de ces fichiers, puis checkpoint.
5. Sois honnête : si une exigence est irréalisable telle quelle (ex. 50 calques pleins à 16K), ne la contourne pas en silence. Explique la limite, propose l'alternative la plus proche et demande-moi de trancher.
6. Ne copie **ni le nom, ni les icônes, ni les assets de Procreate**. Reproduis les principes d'interface et d'architecture, avec une identité visuelle et des icônes originales (SF Symbols autorisés).

---

## 1. Vision

Une application iPad (Apple Pencil + doigt) pour **peindre des cartes HDRI équirectangulaires** (ratio 2:1) comme on peint dans Procreate : on part d'une toile blanche, on peint, on importe des images ou des HDRI, on empile jusqu'à 50 calques avec tous les modes de fusion, puis on **exporte une map HDRI dans le format de son choix** pour l'utiliser dans Unreal Engine 5, Blender, ZBrush ou ailleurs.

Particularités par rapport à Procreate :
- La toile est une **sphère** : l'écran principal est une **vue sphérique immersive** (je suis au centre, je peins autour de moi), avec un bouton de **dépliage** vers la vue équirectangulaire à plat.
- **Aucune distorsion** : un pinceau rond reste rond sur la sphère, y compris aux pôles et à la couture gauche/droite.
- Le **HDR** est natif : des valeurs de lumière supérieures à 1 sont possibles (intensité en EV), avec en option des sources de lumière (soleil, softbox…) et un aperçu d'éclairage.
- **100 % manuel** : aucune IA générative.

---

## 2. Périmètre

**Inclus** : iPad uniquement ; toile jusqu'à 16K ; peinture, calques, fusion, sélection, transformation, ajustements, historique, timelapse, import/export multi-formats, bibliothèque intégrée, import de pinceaux, galerie de projets, préférences et gestes.

**Hors périmètre** : iPhone/Mac/Android/web, comptes, cloud, collaboration, publication sur l'App Store, analytics, toute génération par IA, vidéo autre que le timelapse.

---

## 3. Contraintes techniques et stack

- **Reco (D1) : natif Swift 6 + Metal 3.** UIKit pour la vue de toile (`CAMetalLayer`, gestion brute des touches), SwiftUI pour les panneaux. Pas de PencilKit : tout passe par un moteur de pinceau maison (touches coalescées et prédites, pression, azimut, altitude, roll sur Apple Pencil Pro, hover sur les iPad compatibles).
- Alternative documentée (React + Three.js/WebGPU + Capacitor) : **déconseillée**, car la mémoire du WebView, la latence du stylet et le 16K la rendent très risquée. Ne la propose que si je la demande.
- **Prérequis à vérifier dès la phase 0** : j'ai besoin d'un Mac avec Xcode pour compiler une app iPad native. Demande-moi : modèle d'iPad (mémoire, écran XDR ou non), Mac et version de Xcode disponibles, compte développeur gratuit (installation 7 jours) ou payant (TestFlight). Adapte le plan à la réponse.
- Cible : iPadOS 17+ (D7), iPad à puce M recommandé. Affichage EDR (HDR réel) si l'écran le permet (`wantsExtendedDynamicRangeContent`, espace étendu linéaire Display P3).
- **Structure en Swift Packages testables sur macOS** (`swift test`) : `ZCore` (maths, projections, couleur), `ZImaging` (codecs, import/export), `ZStorage` (tuiles, projet, journal), `ZEngine` (Metal : pinceau, composition, filtres), `ZUI`. Les kernels GPU sont testés sur un GPU Mac via XCTest, contre des **implémentations de référence CPU**.
- Dépendances tierces : minimales. Pour OpenEXR, évalue tinyexr (C++ vendoré) ou un writer maison avec compression zlib du framework Compression (D10).
- Concurrence : Swift Concurrency (acteurs pour le stockage), une file de commandes Metal, triple buffering. Instrumentation `os_signpost` partout où il y a un budget de performance.

---

## 4. Architecture (inspirée de Procreate)

Modules et responsabilités :

| Module | Rôle |
|---|---|
| **Galerie** | Miniatures de projets (aperçu sphère), création, duplication, renommage, suppression, piles, import/export, favoris |
| **Éditeur** | Écran principal : toile, barre du haut, curseurs latéraux, panneaux flottants |
| **Moteur** | Rendu temps réel, pinceau, composition, filtres, sélection, transformation (Metal) |
| **Calques** | Pile, modes de fusion, masques, groupes, écrêtage, verrouillage alpha |
| **Brush Studio** | Édition de pinceaux, bibliothèque, import |
| **Couleur** | Sélecteur, palettes, historique, pipette, gestion HDR/EV |
| **Ajustements** | Courbes, teinte/saturation, flous, etc. |
| **Sélection/Transformation** | Outils spatiaux adaptés à la sphère |
| **Lumière** | Objets lumineux, aperçu d'éclairage, histogramme, sonde |
| **Actions** | Ajouter (import, texte), toile (résolution, guides, référence), partage/export, vidéo, préférences |
| **Historique** | Journal d'opérations, annuler/rétablir, instantanés, timelapse |
| **Import/Export** | Codecs, orientation, cubemap, streaming |
| **Préférences/Gestes** | Réglages complets et remappage des gestes |

Principes : modèle de données séparé du rendu ; toute modification de pixels passe par une **opération journalisée** (pour l'historique et le timelapse) ; chaque outil est un plugin qui implémente un protocole commun (`begin / update / end / cancel`).

---

## 5. Moteur sphérique : zéro distorsion

**Conventions** : direction `d=(x,y,z)`, Y vers le haut. Équirectangulaire : `u = atan2(x,-z)/(2π)+0.5`, `v = acos(y)/π` (v=0 au zénith). Documente-les dans `ARCHITECTURE.md` et teste l'aller-retour (pixel → direction → pixel) sur les pôles, la couture et les coins.

**Peinture** :
- La taille du pinceau est définie en **angle sur la sphère** (conversion depuis les pixels écran selon le FOV courant).
- Chaque *dab* est rendu **par texel équirectangulaire** : on calcule la direction du texel, on la projette dans le **plan tangent** au point d'impact (projection équidistante azimutale), on y échantillonne la forme et le grain du pinceau. Ainsi le tampon est rond sur la sphère quelle que soit la latitude.
- Zone affectée : bande de latitude ±r ; demi-largeur en longitude `asin(sin r / cos lat)` ; si le dab englobe un pôle, on traite toute la rangée. **Gestion du raccord gauche/droite** par bouclage des tuiles, sans couture visible.
- Les traits sont interpolés **sur la sphère** (slerp / splines de quaternions), espacement en angle, stabilisation et lissage réglables.
- L'orientation du pinceau est définie par rapport au « nord local » ou à la verticale écran (option).
- Dans la vue dépliée, l'entrée est reconvertie en direction : le pinceau reste rond **sur la sphère** (donc étiré à l'écran près des pôles). Option « empreinte en espace écran » pour comparer, **désactivée par défaut**.

**Outils spatiaux** : flous, bruit, clonage, doigt, liquify, transformation, sélection et remplissage doivent être **sphériquement corrects** (noyaux dépendants de la latitude, passage par cubemap avec marges si nécessaire). Fais un spike et propose-moi la méthode au checkpoint.

**Outil « Rotation de la sphère »** : yaw/pitch/roll de tout le contenu (utile pour déplacer le soleil ou recaler l'horizon).

---

## 6. Stockage tuilé, mémoire et 16K

Chiffres à respecter dans tes décisions (16K = 16384×8192 = 134 M pixels) :
- RGBA16F : ~1,0 Go par calque **plein** ; RGBA8 : ~0,5 Go ; RGBA32F : ~2,1 Go.
- Donc **50 calques pleins à 16K sont impossibles** sur iPad. Procreate résout ça en limitant dynamiquement le nombre de calques selon la taille de toile. Fais pareil.

Conception :
- Toile découpée en **tuiles** (256² ou 512², D2), stockage **épars** : une tuile jamais touchée n'existe pas ; une tuile uniforme est stockée comme constante.
- Tuiles inactives **compressées en mémoire** (LZ4/LZFSE) puis déversées sur disque ; chargement paresseux à l'ouverture.
- Un **gestionnaire de budget mémoire** (`os_proc_available_memory`) qui évite les crashs : avertissement, suggestion de fusionner des calques, jamais de crash silencieux.
- À la création du projet : je choisis la **résolution** (2K, 4K, 8K, 16K ou 2:1 personnalisé) et le **nombre de calques voulu (1 à 50)**. L'écran affiche le nombre de calques **garanti dans le pire cas** et prévient clairement si mon choix dépasse ce garantie (le stockage épars permet souvent d'aller plus loin).
- Précision de travail (D3) : RGBA16F linéaire par défaut ; option par calque ou par projet en 8 bits pour économiser la mémoire.
- Pyramide de mipmaps générée paresseusement pour l'affichage (LOD).

---

## 7. Couleur et HDR

- **Mêmes couleurs que Procreate** : même logique de sélecteur (disque HSB, classique, harmonie, valeur, palettes avec import `.swatches`), historique de couleurs, pipette par appui long, saisie hexadécimale, profil **Display P3 par défaut** (sRGB en option).
- **Fusion « Procreate-like » (D4)** : par défaut, les modes de fusion sont calculés en espace perceptuel (comme Procreate) pour retrouver les mêmes résultats visuels, avec stockage en flottant linéaire ; extension linéaire de la courbe de transfert au-delà de 1. Option « fusion en lumière linéaire » par projet.
- **Intensité HDR en option** : un curseur d'exposition (en stops EV, de 0 à +16, valeur finale = couleur × 2^EV) attaché à la couleur/au pinceau. Désactivé par défaut : sans lui, je peins en valeurs ≤ 1 comme dans Procreate.
- **Modes de fusion et valeurs > 1** : documente le comportement de chaque mode au-delà de 1 (modes bornés avec écrêtage, `Add`/`Subtract`/`Multiply`/`Divide` non bornés). Tests de référence CPU obligatoires.
- **Affichage** : écrêtage simple (comme Procreate) par défaut ; options de tone mapping (ACES-like, AgX, filmique, D12) avec curseur d'exposition ; **vrai affichage HDR (EDR)** quand l'écran le permet ; indicateur de zones sur-/sous-exposées.

---

## 8. Pinceaux

- Moteur de pinceau complet, façon Brush Studio : forme, grain, espacement, jitter, dynamique de pression/inclinaison/vitesse, rotation, mélange et humidité (pour les pinceaux de mélange), lissage, aperçu en direct.
- Gomme et outil Doigt utilisent le **même moteur** avec leurs propres réglages.
- **Import de pinceaux** : un format natif (`.zenithbrush`) + import **au mieux** de `.brush`/`.brushset` Procreate (extraction des formes/grains et mappage des paramètres compatibles) et `.abr`. Fais d'abord un spike de faisabilité (D9) et dis-moi honnêtement ce qui est supporté ou non. Import de PNG comme forme ou grain.
- Curseurs latéraux de taille et d'opacité, comme Procreate.

---

## 9. Calques et fusion

- 1 à **50 calques** (choix à la création, modifiable tant que la mémoire le permet).
- Opacité, visibilité, verrouillage, **verrouillage alpha**, **masques**, **masque d'écrêtage**, **groupes**, fusion vers le bas, aplatissement, duplication, calque de référence, calque d'arrière-plan (blanc par défaut = valeur 1,0, masquable).
- **Tous les modes de fusion** : Normal, Multiply, Darken, Color Burn, Linear Burn, Darker Color, Lighten, Screen, Color Dodge, Add (Linear Dodge), Lighter Color, Overlay, Soft Light, Hard Light, Vivid Light, Linear Light, Pin Light, Hard Mix, Difference, Exclusion, Subtract, Divide, Hue, Saturation, Color, Luminosity. Plus `Erase` pour les pinceaux.
- **Calques de lumière** (section 12) comme type de calque à part.
- Composition : mise en cache autour du calque actif (calques du dessous aplatis, calques du dessus aplatis) pour garder 60-120 fps ; recomposition uniquement des tuiles sales visibles.

---

## 10. Outils (tous ceux de Procreate, adaptés à la sphère)

Pinceau, gomme, doigt (smudge), **sélection** (automatique, main levée, rectangle, ellipse, ajout/retrait, inversion, adoucissement), **transformation** (libre, uniforme, distorsion, déformation, magnétisme), **remplissage** (ColorDrop avec seuil, glisser-déposer), **dégradés**, **QuickShape**, **symétrie** (axiale, radiale, rotative, sur sphère), **guides** (grille sphérique, horizon, méridiens, aides de perspective), **clonage**, **liquify**, **texte**, pipette, copier/coller, recadrage de la toile (résolution), **mode référence**.

---

## 11. Ajustements et filtres

Teinte/saturation/luminosité, balance des couleurs, **courbes** (y compris au-delà de 1 en mode HDR), carte de dégradé, recoloration, flou gaussien/directionnel/de mouvement/en perspective, bruit, netteté, bloom, aberration chromatique, halftone, glitch. Application par calque ou par pinceau (Pencil), avec aperçu en direct. **Tous sphériquement corrects.**

---

## 12. Lumière et aperçu (optionnels)

Tu dois pouvoir ignorer cette section dans le MVP et la livrer en phase 8, mais l'architecture doit la prévoir.

- **Calques de lumière** non destructifs : soleil (azimut/élévation, température en Kelvin, intensité en EV, diamètre angulaire ~0,53°), disque/softbox (taille et adoucissement en degrés), spot/point chaud, bande lumineuse (rim light), dégradé de ciel. Poignées directement sur la sphère. On peut **les rastériser** pour repeindre dessus.
- **Cohérence énergétique** : l'intensité tient compte de l'angle solide (pondération en cos(latitude)) pour qu'une source garde la même énergie quelle que soit sa taille.
- **Aperçu d'éclairage** : panneau flottant avec sphères d'essai (chrome, gris mat 18 %, blanc diffus, un matériau textile simple avec sheen), préfiltrage incrémental sur les tuiles modifiées, basse résolution pour rester fluide (D11).
- **Outils de mesure** : histogramme de luminance (échelle log), sonde de luminance/température de couleur/EV au toucher, zébrures sur les zones écrêtées.

---

## 13. Vues, navigation, gestes

**Trois vues, au choix à tout moment** (D5) :
- **A. Sphère immersive** (vue par défaut) : caméra au centre, projection rectilinéaire, FOV de 20° à 150°.
- **B. Dépliée (équirectangulaire à plat)** : bouton de **dépliage** en barre du haut avec animation de morphing sphère → plan (~0,6 s).
- **C. Fenêtre plane** : une vue rectilinéaire verrouillée face à une direction choisie (boutons de raccourci pour les 6 faces) pour peindre comme sur une image plate.

**Gestes** (tous remappables dans les préférences) :
- 1 doigt/Pencil : peindre (réglage « le doigt navigue au lieu de peindre »).
- 2 doigts pincer : zoom (FOV en A, échelle en B) ; 2 doigts glisser : regarder autour/déplacer ; 2 doigts tourner : roll (option « verrouiller l'horizon », active par défaut en A).
- **Double tap à 2 doigts = annuler** (mon geste demandé, D6) ; double tap à 3 doigts = rétablir ; maintien 2 doigts = annulation rapide continue. Pas de latence parasite car le tap simple n'a pas d'action.
- Glisser 3 doigts vers le bas = copier/coller ; frotter 3 doigts = effacer le calque ; tap 4 doigts = masquer l'interface ; appui long = pipette ; tracer puis maintenir = QuickShape.
- Apple Pencil : double tap/squeeze configurable ; curseur de survol sur la sphère (empreinte réelle du pinceau).

---

## 14. Historique, timelapse, sauvegarde

- Historique via **journal d'opérations avec deltas de tuiles compressés**, annuler/rétablir **sans limite pratique** (plafond réglable, défaut 1 000 pas, débordement sur disque), panneau d'historique visuel, annulation rapide par maintien.
- **Instantanés** nommés (points de sauvegarde) et duplication de projet.
- **Timelapse** : enregistrement automatique des opérations, export vidéo H.265 (AVAssetWriter), vue sphère ou dépliée.
- **Sauvegarde automatique** continue et à la mise en arrière-plan, récupération après crash.

---

## 15. Import et export

**Import** (Fichiers, Photos, glisser-déposer, presse-papiers) : PNG, JPG, HEIC, TIFF, **EXR** (half/float), **HDR Radiance**, PSD (aplati). Trois modes : A) panorama équirectangulaire complet (rééchantillonnage ; si le ratio n'est pas 2:1, je choisis recadrage ou marges) ; B) image plate posée comme patch rectilinéaire au centre de la vue, avec FOV réglable, puis transformable ; C) cubemap (6 faces ou croix) converti en équirectangulaire.

**Export — je choisis le format à chaque fois** :
- **.exr** (16 ou 32 bits, RGB/RGBA, compression aucune/ZIP/PIZ), **.hdr** (Radiance RGBE), **PNG** 8/16 bits, **JPG** (qualité), **TIFF** 16/32 bits ; **cubemap** (6 faces, croix, ou prêt pour UE5) ; projet natif `.zenith`.
- Options : résolution de sortie (≤ projet, ou lot 1K/2K/4K en une fois), **préréglage d'orientation** (Blender, UE5, Unity, générique) avec décalage de yaw et retournement, export tone-mappé LDR avec exposition choisie, calques visibles uniquement ou un seul calque, fond transparent.
- **Export en flux** par bandes de lignes (par ex. 256 lignes) pour éviter les pics de mémoire à 16K ; exécution en arrière-plan avec progression et annulation ; partage via Fichiers/AirDrop/feuille de partage. Après export, **relecture et comparaison** automatiques (PSNR) en test.

---

## 16. Bibliothèque intégrée

Aucun contenu protégé : tout est généré procéduralement ou dessiné en vecteur, et je peux ajouter les miens.
- **Préréglages de ciel** modifiables (modèle de ciel clair Hosek-Wilkie ou Preetham avec turbidité et position du soleil ; dégradés ; couvert CIE ; nuit étoilée ; studios 3 points, anneau softbox, cyclo blanc).
- **Pinceaux** : nuages (cumulus, stratus, cirrus), étoiles (magnitudes → intensités HDR), brume, rayons crépusculaires, étincelles, feuillage/herbe.
- **Tampons** : soleil, lune, softbox, néon, fenêtre lumineuse, **silhouettes d'horizon** (collines, pins, bâtiments simples).
- Navigateur de bibliothèque par catégories, favoris, import/export.

---

## 17. Interface (comme Procreate, identité originale)

- Barre du haut à gauche : Galerie, Actions, Ajustements, Sélection, Transformation. À droite : Pinceau, Doigt, Gomme, Calques, Couleur. **Bouton de dépliage** bien visible.
- Colonne gauche : curseurs de taille et d'opacité verticaux, boutons annuler/rétablir, bouton « modifier ».
- Panneaux flottants et fermables, thème sombre par défaut (+ clair), mode gaucher, interface masquable (tap 4 doigts).
- Préférences : courbe de pression, gestes, profil colorimétrique, fusion Procreate-like/linéaire, tone mapping, historique, affichage EDR.

---

## 18. Performance, qualité, tests

**Budgets** : navigation ≥ 120 fps à 8K et ≥ 60 fps à 16K (≤ 20 calques denses) grâce au LOD ; latence perçue du trait ≤ 16 ms avec prédiction ; annulation ≤ 150 ms typique ; ouverture de projet 8K < 3 s ; gestion thermique (réduction de qualité dynamique avant la limitation système).

**Tests obligatoires** : aller-retour des projections (pôles, couture) ; pinceau rond mesuré sur la sphère à plusieurs latitudes ; chaque mode de fusion contre sa référence CPU (y compris > 1) ; journal d'historique (annuler/rétablir exact au bit près) ; stockage épars et débordement disque ; export/réimport de chaque format avec comparaison ; stress mémoire à 16K ; profils Instruments (Metal System Trace, Allocations) joints aux phases concernées.

---

## 19. Plan par phases et checkpoints

À chaque phase : livrables, définition de fini, mise à jour des docs, puis questions de checkpoint.

- **Phase 0 — Cadrage** : poser les questions matérielles (iPad, Mac, Xcode, signature), squelette du projet, `CLAUDE.md`. Décisions : **D1** stack, **D7** version minimale d'iPadOS/appareil, **D8** nom et identifiant de bundle.
- **Phase 1 — Fondations** : `ZCore` (projections, maths, couleur) avec tests ; tuiles éparses ; format de projet ; journal d'opérations. Décisions : **D2** taille de tuile (spike 256 vs 512), **D3** précision de stockage.
- **Phase 2 — Visualisation** : vue sphère, dépliage animé, vue fenêtre plane, navigation tactile, LOD 16K, affichage EDR. Décisions : **D5** confirmation des trois vues, **D12** tone mapping par défaut.
- **Phase 3 — Cœur de peinture** : moteur de pinceau sphérique sans distorsion, gomme, sélecteur de couleur, un calque, annulation, geste double tap 2 doigts. Décisions : **D4** espace de fusion, **D6** mapping des gestes d'historique.
- **Phase 4 — Calques** : pile jusqu'à 50, tous les modes de fusion, masques, groupes, écrêtage, verrouillage alpha, cache de composition, budget mémoire.
- **Phase 5 — Outils** : sélection, transformation, remplissage, dégradés, doigt, clonage, liquify, QuickShape, symétrie, guides, texte, rotation de sphère.
- **Phase 6 — Ajustements/filtres** sphériques.
- **Phase 7 — Import/export** : tous les codecs, orientation, cubemap, export en flux, import de pinceaux (**D9**), timelapse. Décision : **D10** bibliothèque EXR.
- **Phase 8 — HDR et lumière** : curseur EV, calques de lumière, aperçu d'éclairage, histogramme, sonde. Décision : **D11** matériaux de l'aperçu.
- **Phase 9 — Bibliothèque, galerie, préférences, finitions** : bibliothèque intégrée, galerie complète, remappage des gestes, passe de performance, passe de tests, récupération après crash.

**MVP rapide possible** (si je veux tester vite) : phases 0 → 3 + export EXR/HDR simple, puis le reste.

---

## 20. Documentation à produire et maintenir

`CLAUDE.md` (contraintes, conventions, commandes de build/test), `ARCHITECTURE.md` (modules, conventions de projection, format de projet, pipeline de rendu), `DECISIONS.md` (journal D1…), `ROADMAP.md` (phases, état), `TESTING.md` (comment lancer les tests et profils).

---

## 21. Ta première action

1. Lis ce document en entier et résume-le-moi en 10 lignes maximum.
2. Pose-moi les questions matérielles de la phase 0 (modèle d'iPad, Mac et Xcode, compte développeur) et les décisions D1, D7, D8 via l'outil de questions.
3. Crée le squelette du dépôt et les fichiers de documentation, puis lance le **spike de la phase 1** (projection et pinceau sphérique sans distorsion, mesure de mémoire à 16K) avant tout le reste.
