> **Brouillon d'une autre session (2026-10-25), non maintenu.** La référence est [ARCHITECTURE.md](../ARCHITECTURE.md) à la racine ; certaines idées ici (tuiles 512², annulation par rejeu du journal) ont été écartées, voir DECISIONS.md.

# Architecture de ProRange Creator

**Version** : 0.1 (draft — phase 0 spike)  
**Date** : 2026-10-25  
**Auteur** : Pauly + Claude Code

---

## 1. Vue d'ensemble

ProRange Creator est une application iPad native (Swift 6, Metal 3) pour peindre des HDRI équirectangulaires 2:1.  
Cible : iPad Air 5 (M1, 8 Go, SDR, Apple Pencil 2). Usage personnel, aucune publication.

### 1.1 Objectifs architecturaux

| Objectif | Choix |
|---|---|
| **Sans distorsion** | Pinceau circulaire sur la sphère (projection azimutale équidistante) |
| **16K en 8 Go** | Tuiles creuses 512², chargement paresseux, compression LZFSE |
| **Annulation instantanée** | Journal d'opérations (command pattern) + checkpoints |
| **HDR correct** | Espace de travail RGB linéaire prémultiplié ; conversion sRGB/P3 seulement à l'entrée/sortie |
| **Testable** | Chaque kernel GPU a une implémentation CPU de référence dans PRCore + test de comparaison |
| **CI reproductible** | XcodeGen → pas de `.xcodeproj` versionné ; GitHub Actions `macos-15` |

---

## 2. Structure des modules (Swift Packages)

```
ProRangeCreator/
├── App/                      # Cible iPad (SwiftUI + UIKit)
│   ├── SpikeCanvasView.swift      # Spike phase 0 (2K CPU)
│   └── …                          # Vues finales : toile, sphère, panneaux
│
└── Packages/ProRangeKit/     # Package local
    ├── PRCore/            # Maths, projections, couleur, rasteriseur CPU de référence
    ├── PRImaging/         # Codecs : EXR (half), HDR, PNG, JPEG-XL (futur)
    ├── PRStorage/         # Tuiles, projet, journal d'opérations
    ├── PREngine/          # Metal : shaders, pipelines, gestion VRAM
    └── PRUI/              # Composants SwiftUI réutilisables (pickers, sliders, etc.)
```

### 2.1 PRCore — Cœur algorithmique (pur Swift, `@Sendable`)

| Fichier | Responsabilité |
|---|---|
| `Spherical.swift` | `Equirect` (uv ↔ direction), `TangentFrame` (plan tangent, projection azimutale équidistante), `Sphere` (angle, slerp), `SphericalStrokeSampler` |
| `ReferenceRasterizer.swift` | `EquirectCanvas` (toile CPU 2:1, RGBA float linéaire prémultiplié), `SphericalDab`, `SphericalRasterizer` (couverture, blend, span) |
| `ColorTransfer.swift` | sRGB ↔ linéaire, P3 ↔ linéaire, encodage 8/16 bits, OETF/EOTF |
| `TileMath.swift` | Indexation tuiles, morton order, calcul de mip-level, seuils de chargement |
| `Operations.swift` | Types d'opérations journalisées (`StrokeOp`, `EraseOp`, `FillOp`, `TransformOp`…) |

### 2.2 PRImaging — Codecs

- `EXRCodec` : lecture/écriture half-float (canaux R/G/B + A), compression ZIP/DWA
- `HDRCodec` : Radiance `.hdr` (RGBE)
- `PNGCodec` : 8/16 bits, sRGB/P3 tagged
- **Pas de dépendance externe lourde** : implémentations minimales + `vImage`/`ImageIO` pour le décodage final

### 2.3 PRStorage — Persistance

```
Projet (.prrange)  ←  package (FileWrapper)
├── manifest.json          # métadonnées, version, palette, résolution de base
├── tiles/                 # tuiles LZFSE compressées
│   ├── level0/            # 512² (ou 256² — décision D2)
│   ├── level1/            # 256²
│   └── …
├── journal/               # opérations (binaire, append-only)
│   ├── 000001.oplog
│   └── …
└── checkpoints/           # snapshots périodiques (tous les N ops ou temps)
    ├── cp-001.tiles
    └── …
```

- **Tuiles** : 512×512 RGBA16F (half) → 2 Mo brute → ~300–600 Ko compressée LZFSE
- **Journal** : binaire structuré (tag + longueur + payload), `Sendable`, replayable
- **Checkpoints** : copie des tuiles modifiées + index journal → annulation O(1) depuis checkpoint

### 2.4 PREngine — Metal

| Composant | Rôle |
|---|---|
| `TileRenderer` | Render pass par tuile (compute → fragment blit) |
| `BrushPipeline` | Shader pinceau (distance dans plan tangent, couverture, blend) |
| `SphereViewRenderer` | Vue 3D : sphère texturée, éclairage IBL, post-process tonemap |
| `UnfoldAnimation` | Compute shader : dépliage sphère → plan (morphing u/v) |
| `VRAMManager` | Budget VRAM, éviction LRU, préchargement voisinage brosse |
| `TextureCache` | `MTLTexture` par tuile (mipmaps optionnels), clé = (level, tileX, tileY) |

### 2.5 PRUI — Composants SwiftUI

- `ColorPickerHDR` : roue HSV + curseur exposition, valeurs linéaires internes
- `BrushEditor` : rayon (°), dureté, forme (rond, carré, custom), espacement
- `LayerPanel` : liste calques, visibilité, opacité, mode de fusion
- `HistorySidebar` : journal visuel (miniatures), recherche, sauts
- `GuidesOverlay` : équateur, méridiens, grille lat/long, couture

---

## 3. Conventions de projection équirectangulaire

Toutes les formules sont dans **PRCore/Spherical.swift** (source de vérité).

### 3.1 Système de coordonnées

- **Sphère** : Y vers le haut, Z vers l'avant (-Z = face avant), X vers la droite
- **Équirectangulaire** :
  - `u ∈ [0, 1]` : longitude, `u = 0.5` face à -Z, croissant vers +X
  - `v ∈ [0, 1]` : latitude, `v = 0` zénith (+Y), `v = 1` nadir (-Y)
- **Angles** : **radians** dans tout le code, **degrés** seulement dans l'UI

### 3.2 Formules de référence

```swift
// Direction → uv
u = atan2(x, -z) / 2π + 0.5
v = acos(clamp(y, -1, 1)) / π

// uv → direction
θ = v * π
φ = (u - 0.5) * 2π
dir = [ sin(θ) * sin(φ), cos(θ), -sin(θ) * cos(φ) ]

// Latitude / longitude (radians)
lat = asin(clamp(y, -1, 1))           // +π/2 au zénith
lon = atan2(x, -z)                    // [-π, π], 0 face à -Z
```

### 3.3 Plan tangent — projection azimutale équidistante

Pour un centre `C` (unitaire) :

```
east  = normalize(cross(C, [0,1,0]))  // +X au pôle nord exact
north = cross(east, C)
```

Projection d'une direction `D` dans le plan tangent :

```
cosα = dot(C, D)
t    = D - C * cosα
sinα = length(t)
k    = atan2(sinα, cosα) / sinα       // α / sinα  (≈ 1 pour petits α)
p    = [ dot(t, east) * k, dot(t, north) * k ]   // en radians
```

**Propriété clé** : `length(p) = α` (angle sur la sphère).  
Un disque dans le plan tangent = un cercle sur la sphère → **pinceau sans distorsion**.

Inverse (plan tangent → sphère) :

```
α = length(p)
if α < ε { return C }
dir = (east * p.x + north * p.y) / α
return C * cos(α) + dir * sin(α)
```

---

## 4. Stockage en tuiles (décision D2 : **512²**)

### 4.1 Justification 512² vs 256²

| Critère | 256² | 512² (choisi) |
|---|---|---|
| Tuiles 16K (niveau 0) | 256 × 128 = 32 768 | 128 × 64 = 8 192 |
| VRAM par tuile (RGBA16F) | 512 Ko | 2 Mo |
| Tuiles simultanées (budget 1.5 Go) | ~3 000 | ~750 |
| Overhead métal (descriptors, etc.) | +4× | **1×** |
| Granularité chargement/éviction | fine | **acceptable** |
| Compression LZFSE (ratio typique) | 3–4× | 3–4× |
| Latence chargement disque → GPU | plus d'appels | **moins d'appels** |

**Décision** : 512² réduit l'overhead Metal et le nombre d'appels I/O. La granularité reste suffisante car le pinceau max (45°) couvre ~64 tuiles à 16K.

### 4.2 Pyramide de tuiles

| Niveau | Résolution | Tuiles (L×H) | Taille tuile | Usage |
|---|---|---|---|---|
| 0 (base) | 16 384 × 8 192 | 32 × 16 = 512 | 512² | Édition |
| 1 | 8 192 × 4 096 | 16 × 8 = 128 | 512² | Zoom -1 |
| 2 | 4 096 × 2 048 | 8 × 4 = 32 | 512² | Zoom -2 |
| 3 | 2 048 × 1 024 | 4 × 2 = 8 | 512² | Aperçu rapide |
| 4 | 1 024 × 512 | 2 × 1 = 2 | 512² | Vignette |
| 5 | 512 × 256 | 1 × 1 = 1 | 512² | Miniature |

Total tuiles : ~683 par calque. À 4 calques max : ~2 700 tuiles.

### 4.3 Format tuile sur disque

```
TileFile (LZFSE compressed) :
  Header (32 octets) :
    u32 magic = 0x5052544C ('PRTL')
    u16 version = 1
    u16 level
    u16 tileX, tileY
    u16 width, height (toujours 512 sauf bord)
    u32 crc32 (données décompressées)
  Payload : RGBA half-float linéaire prémultiplié (width × height × 8 octets)
```

### 4.4 Chargement paresseux & préchargement

- **Demand-driven** : tuile chargée au premier accès (lecture ou écriture)
- **Préchargement brosse** : au `strokeBegan`, calculer le `TangentFrame` → déterminer les tuiles intersectées par le disque de rayon `radius + 2px` → lancer chargement asynchrone
- **Éviction** : LRU par niveau, budget VRAM configurable (défaut 1.2 Go / 1.5 Go max)

---

## 5. Gestion mémoire (budget 8 Go iPad Air 5)

### 5.1 Budget VRAM (Metal)

| Poste | 16K × 1 calque | 4 calques | Notes |
|---|---|---|---|
| Tuiles niveau 0 (résidentes) | 512 × 2 Mo = 1 Go | 4 Go | **Trop** → seulement tuiles actives |
| Tuiles actives (brosse 45°) | ~64 tuiles = 128 Mo | 512 Mo | Cible : < 500 Mo |
| Mipmaps (niveaux 1–5) | ~200 Mo | 200 Mo | Partagés entre calques |
| Framebuffers (2× 16K RGBA16F) | 2 × 1 Go = 2 Go | — | **Pas de framebuffer 16K complet** |
| Shaders, vertex buffers, etc. | ~50 Mo | ~50 Mo | |
| **Total visé** | **~500 Mo** | **~800 Mo** | Dans budget 1.5 Go VRAM |

**Stratégie** : **pas de framebuffer 16K complet**. Rendu par tuile (tile-based deferred) :
- `TileRenderer` : chaque tuile rendue dans un `MTLTexture` 512² attaché à un `MTLRenderPassDescriptor` minimal
- Composition finale à l'affichage (écran 2K/4K) via shader de tonemap + upscale

### 5.2 Budget RAM (CPU)

| Poste | Estimation |
|---|---|
| Journal d'opérations (10 000 ops) | ~50 Mo |
| Checkpoints (tous les 100 ops, 4 calques) | ~200 Mo |
| Cache tuiles déchiffrées (LRU 200 tuiles) | ~400 Mo |
| Undo/redo stack (métadonnées) | ~10 Mo |
| **Total CPU** | **~700 Mo** |

Total combiné VRAM + RAM < 2 Go → confortable sur 8 Go (iOS réserve ~2–3 Go).

---

## 6. Pipeline de rendu

### 6.1 Rendu toile (édition 2D dépliée)

```
Entrée : tuiles modifiées (dirty set) + brosse courante
          │
          ▼
TileRenderer (compute shader)
  • Charge tuiles sources (VRAM)
  • Pour chaque dab du trait :
      - TangentFrame au centre
      - Projette texels couverts dans plan tangent
      - Calcule couverture (distance / radius, dureté)
      - Blend source-over prémultiplié
  • Écrit tuile résultat (VRAM + marque dirty disque)
          │
          ▼
Affichage (fragment shader quad full-screen)
  • Échantillonne tuiles visibles (niveau selon zoom)
  • Tonemap (AgX / ACES) + espace couleur écran (sRGB/P3)
  • Guides (équateur, méridiens, couture) en overlay
```

### 6.2 Rendu sphère (vue 3D)

```
SphereViewRenderer (render pass unique)
  • Géométrie : sphère UV subdivisée (icosphère 642 vertices)
  • Vertex shader : position + uv sphérique
  • Fragment shader :
      - Échantillonne tuiles (mipmap auto)
      - Éclairage IBL (prefiltered environment map)
      - Tonemap + gamma
  • Post-process : vignette, grille lat/long optionnelle
```

### 6.3 Animation dépliage (sphère ↔ plan)

```
UnfoldAnimation (compute shader, 60 fps cible)
  • Paramètre t ∈ [0, 1] : 0 = sphère, 1 = plan équirectangulaire
  • Position vertex = mix(spherePos, planePos, easeInOut(t))
  • UV = mix(sphereUV, planarUV, t)
  • Texture : échantillonnage unique (tuiles niveau selon zoom)
  • Durée : 400 ms (spring damping 0.8)
```

---

## 7. Format de projet (.prrange)

### 7.1 manifest.json

```json
{
  "version": 1,
  "baseResolution": { "width": 16384, "height": 8192 },
  "tileSize": 512,
  "colorSpace": "linear-premultiplied",
  "encoding": "rgba16f",
  "compression": "lzfse",
  "layers": [
    { "id": "layer-0", "name": "Base", "visible": true, "opacity": 1.0, "blendMode": "normal" },
    { "id": "layer-1", "name": "Details", "visible": true, "opacity": 1.0, "blendMode": "normal" }
  ],
  "palette": [ { "name": "Sky", "rgb": [0.15, 0.35, 0.85] }, … ],
  "created": "2026-10-25T14:30:00Z",
  "modified": "2026-10-25T15:45:00Z",
  "journalVersion": 42
}
```

### 7.2 Journal d'opérations (binaire append-only)

Chaque entrée :

```
struct OpEntry {
    u32  tag              // 0x5354524B ('STRK'), 0x45525345 ('ERSE'), …
    u32  length           // payload length (octets)
    u64  timestamp        // mach_absolute_time
    u32  layerId          // index dans manifest.layers
    // payload spécifique au tag
}
```

**Types d'opérations** :

| Tag | Nom | Payload |
|---|---|---|
| `STRK` | StrokeOp | `u32 dabCount`, `dabCount × { Vec3 center, f32 radius, f32 hardness, SIMD4<f32> color }` |
| `ERSE` | EraseOp | Même structure que `STRK` (couleur = transparent) |
| `FILL` | FillOp | `u32 tileCount`, `tileCount × { u16 level, u16 tx, u16 ty, u32 crc32 }` |
| `XFRM` | TransformOp | `mat3x3` (rotation sphérique), `affectedTileMask` |
| `CHPT` | Checkpoint | `u64 journalOffset`, `tileManifestHash` |

### 7.3 Replay & annulation

- **Undo** : reculer dans le journal, rejouer depuis dernier checkpoint avant l'op visée
- **Redo** : rejouer les ops annulées
- **Checkpoint automatique** : toutes les 100 ops **ou** 30 s d'inactivité
- **Compaction** : au `save`, réécrire le journal depuis le dernier checkpoint valide

---

## 8. Pipeline couleur / HDR

### 8.1 Espace de travail

- **RGB linéaire prémultiplié** (alpha déjà multiplié dans R/G/B)
- Précision : `Float16` (half) en VRAM, `Float32` en CPU (PRCore)
- Gamut : **rec.2020** (conteneur) — valeurs > 1.0 autorisées (HDR)

### 8.2 Conversions

| Étape | Conversion |
|---|---|
| **Sélecteur couleur (UI)** | sRGB/P3 (utilisateur) → linéaire (travail) via `ColorTransfer.toLinear()` |
| **Import EXR/HDR** | Décodage half → linéaire (déjà linéaire) |
| **Import PNG/JPEG sRGB** | sRGB → linéaire |
| **Import PNG P3** | P3 → linéaire (matrice P3→rec2020) |
| **Affichage toile (SDR)** | Linéaire → tonemap (AgX) → sRGB/P3 (écran) → encodage 8 bits |
| **Affichage sphère (HDR)** | Linéaire → tonemap (ACES) → P3 (si écran XDR, sinon sRGB) |
| **Export EXR** | Linéaire → half-float (pas de tonemap) |
| **Export HDR/PNG** | Linéaire → tonemap optionnel → encodage cible |

### 8.3 Tonemapping

- **AgX** (par défaut) : conçu pour rendu, préserve les hautes lumières, pas de "flare" artificiel
- **ACES** (optionnel) : look cinématographique
- **Linéraire** (debug) : clamp [0,1] seulement

Implémentation dans `ColorTransfer.swift` + shader Metal `tonemap.metal`.

---

## 9. Moteur de pinceau (Brush Engine)

### 9.1 Modèle de pinceau

```swift
struct BrushDescriptor: Sendable {
    var radiusDegrees: Double      // 1° – 45°
    var hardness: Double           // 0.0 – 1.0
    var spacing: Double            // facteur × radius (défaut 0.15)
    var shape: BrushShape          // .round, .square, .custom(Data)
    var dynamics: BrushDynamics    // pression, inclinaison, vélocité → radius/opacity/spacing
    var blendMode: BlendMode       // .normal, .add, .multiply, .erase
}
```

### 9.2 Dynamiques Apple Pencil 2

| Entrée | Mappage |
|---|---|
| **Pression** (0–1) | `radius × (0.2 + 0.8 × pressure)` / `opacity × pressure` |
| **Inclinaison** (altitude 0–π/2) | Ellipticité : `radiusMinor = radius × sin(altitude)` |
| **Double tap** | Bascule gomme / pinceau (configurable) |
| **Azimut** | Rotation de la forme custom |

### 9.3 Algorithme de trait (SphericalStrokeSampler)

1. `strokeBegan(uv)` → `Equirect.direction(u,v)` → `Vec3` centre
2. `TangentFrame(center)` créé
3. `sampler.begin(at: center)` → premier dab
4. `strokeMoved(uv)` → nouveau `Vec3` → `sampler.add(d, spacing)` → centres interpolés sur grand cercle (slerp)
5. Pour chaque centre : `SphericalDab` → `SphericalRasterizer.stamp()` (CPU) ou `BrushPipeline` (GPU)
6. `strokeEnded()` → finaliser l'opération, écrire dans le journal

### 9.4 Gomme

Identique au pinceau mais `blendMode = .erase` → `color = [0,0,0,0]` (transparent prémultiplié).  
Le blend source-over avec alpha=0 efface correctement (reprend la destination).

### 9.5 Sélecteur de couleur (color picker)

- **Écran** : échantillonne la texture affichée (post-tonemap) → inverse tonemap → linéaire
- **Sphère** : raycast sphère → UV → échantillonne tuile → linéaire
- **Pipette moyenne** : moyenne sur disque 1° (option)

---

## 10. Calques & Composition

### 10.1 Modèle de calque

- Max **4 calques** (contrainte mémoire)
- Chaque calque = pyramide de tuiles indépendante
- Ordre : bas → haut (painter's algorithm)
- Propriétés : nom, visibilité, opacité (0–1), mode de fusion

### 10.2 Modes de fusion (dans l'espace linéaire prémultiplié)

| Mode | Formule (src sur dst) |
|---|---|
| `normal` | `src + dst * (1 - src.a)` |
| `add` | `src + dst` |
| `multiply` | `src * dst + dst * (1 - src.a)` |
| `screen` | `1 - (1 - src) * (1 - dst)` (adapté prémultiplié) |
| `overlay` | `multiply` si `dst < 0.5` else `screen` |
| `erase` | `dst * (1 - src.a)` |

Implémentés dans `PRCore/Blending.swift` (CPU) + `blend.metal` (GPU).

### 10.3 Composition finale (affichage)

```
Pour chaque pixel visible (niveau de tuile selon zoom) :
    acc = background (noir ou damier)
    pour layer dans layers (bas → haut) :
        si layer.visible :
            acc = blend(layer.sample(uv), acc, layer.blendMode, layer.opacity)
    acc = tonemap(acc)
    acc = colorspaceConvert(acc, target: displaySpace)
```

---

## 11. Interface utilisateur (SwiftUI + UIKit)

### 11.1 Architecture vue

```
App/
├── ProRangeApp.swift              # @main, WindowGroup
├── ContentView.swift              # Conteneur principal (split view)
├── CanvasViewController.swift     # UIViewControllerRepresentable → CAMetalLayer
├── SphereViewController.swift     # Vue 3D (MetalKit)
├── Panels/
│   ├── BrushPanel.swift           # Éditeur pinceau (SwiftUI)
│   ├── LayerPanel.swift           # Liste calques
│   ├── ColorPanel.swift           # Sélecteur HDR + palette
│   ├── HistoryPanel.swift         # Journal visuel
│   └── GuidesPanel.swift          # Options guides
└── Gestures/
    ├── CanvasGestures.swift       # Drag (pinceau), pinch (zoom), rotate (vue sphère)
    └── PencilInteraction.swift    # Pression, inclinaison, double-tap
```

### 11.2 Gestion Apple Pencil

- `UIIndirectScribbleInteraction` désactivé (on gère nous-mêmes)
- `UIPencilInteraction` pour double-tap → action configurable
- `touchesEstimatedPropertiesExpectUpdates` pour prédiction faible latence
- `UIPencilInteractionDelegate` : `pencilInteractionDidTap` → toggle gomme

### 11.3 Raccourcis clavier (clavier physique / Smart Keyboard)

| Raccourci | Action |
|---|---|
| `B` | Pinceau |
| `E` | Gomme |
| `I` | Pipette |
| `[` / `]` | Rayon - / + |
| `Shift+[` / `Shift+]` | Dureté - / + |
| `Cmd+Z` | Annuler |
| `Shift+Cmd+Z` | Rétablir |
| `Space + drag` | Pan toile |
| `Option + drag` | Zoom (pinch simulé) |

---

## 12. Tests & validation

### 12.1 Stratégie de test

| Niveau | Outil | Couverture |
|---|---|---|
| **Unitaire (PRCore)** | Swift Testing | `Equirect`, `TangentFrame`, `Sphere`, `SphericalRasterizer.coverage`, `ColorTransfer` |
| **Comparaison CPU/GPU** | Test personnalisé | Chaque kernel Metal vs référence CPU (tolérance 1/65535 en half) |
| **Intégration** | XCTest + `XCTSkip` sans GPU | Chargement tuiles, journal replay, undo/redo |
| **Visuel (spike)** | App sur iPad | Grille de test (pôles, couture, équateur), latence, mémoire |
| **Performance** | Instruments + spike | FPS, VRAM, temps trait, allocation |

### 12.2 Grille de test de référence (dans SpikeCanvasModel)

```
Latitudes : 0°, 30°, 60°, 75°, 85°, 90° (zénith)
Longitudes : 0° (méridien central), 180° (couture), ±45°, ±80°
Vérifications visuelles :
  • Disque parfait à l'équateur
  • Étirement progressif vers les pôles (correct)
  • Pas de raccord à u=0/1 (couture)
  • Pas d'artefact au pôle exact
```

### 12.3 Tests de non-régression Metal

```swift
// Exemple de test comparatif
func testBrushKernelMatchesCPU() {
    let canvas = EquirectCanvas(width: 1024, height: 512, fill: .zero)
    let dab = SphericalDab(center: [0,1,0], radius: .pi/18, hardness: 0.7, color: [1,0,0,1])
    
    // CPU
    SphericalRasterizer.stamp(dab, on: canvas)
    let cpuPixels = canvas.pixels
    
    // GPU
    let gpuCanvas = try TileRenderer.render(dab: dab, on: canvas)
    let gpuPixels = gpuCanvas.pixels
    
    // Comparaison
    for (cpu, gpu) in zip(cpuPixels, gpuPixels) {
        #expect(abs(cpu.x - gpu.x) < 1/65535)
        #expect(abs(cpu.y - gpu.y) < 1/65535)
        #expect(abs(cpu.z - gpu.z) < 1/65535)
        #expect(abs(cpu.w - gpu.w) < 1/65535)
    }
}
```

---

## 13. Décisions en attente / ouvertes

| ID | Sujet | Options | Recommandation |
|---|---|---|---|
| **D1** | Résolution de base | 8K / **16K** / 32K | **16K** (objectif cahier des charges) |
| **D2** | Taille tuile | 256² / **512²** | **512²** (décidé ci-dessus) |
| **D3** | Compression tuiles | LZ4 / **LZFSE** / Zstd | **LZFSE** (natif Apple, bon ratio/vitesse) |
| **D4** | Format journal | Binaire custom / **FlatBuffers** / MessagePack | **Binaire custom** (simple, pas de dépe, append-only) |
| **D5** | Tonemap par défaut | **AgX** / ACES / Reinhard | **AgX** (meilleur pour HDRI) |
| **D6** | Mipmaps GPU | Générés à la volée / **Prégénérés au chargement** | **Prégénérés** (coût CPU une fois, gain GPU) |
| **D7** | Synchronisation journal | Immédiate / **Batch (100 ms)** / À la sauvegarde | **Batch 100 ms** (perf + durabilité) |

---

## 14. Feuille de route (phases)

| Phase | Objectif | Livrable | Critère de fin |
|---|---|---|---|
| **0** ✅ | Spike pinceau sphérique 2K CPU | `SpikeCanvasView`, `Spherical`, `ReferenceRasterizer` | CI verte, pinceau rond sur sphère, couture OK |
| **1** | Stockage tuiles + journal | `PRStorage`, format `.prrange`, undo/redo | Projet 16K s'ouvre/sauve, undo instantané |
| **2** | Visualisation | Vue sphère Metal, animation dépliage, fenêtre plane | 60 fps sphère, dépliage fluide 400 ms |
| **3** | Moteur pinceau complet | Pinceau Metal, gomme, pipette, 1 calque, undo 2-doigt | Latence < 16 ms/trait, pas de lag visuel |
| **4** | Calques + composition | 4 calques, modes fusion, opacité, panneaux UI | Composition correcte, UI responsive |
| **5** | Import/Export | EXR, HDR, PNG, JPEG-XL | Round-trip EXR bit-exact (sans tonemap) |
| **6** | Polish & spike iPad | Tests réels iPad Air 5, optimisations, bugs | Paul valide sur device |

Chaque phase se termine par : **CI verte → démo décrite → MAJ ARCHITECTURE/DECISIONS/ROADMAP/TESTING → checkpoint Paul (AskUserQuestion, 4 questions max, option recommandée en premier). Sans réponse : appliquer la recommandation et la noter dans DECISIONS.md.**

---

## 15. Références croisées

- `docs/CAHIER-DES-CHARGES.md` — exigences complètes
- `docs/DECISIONS.md` — journal des décisions (D1–D7)
- `docs/ROADMAP.md` — jalons détaillés par phase
- `docs/TESTING.md` — plan de test complet
- `Packages/ProRangeKit/Sources/PRCore/Spherical.swift` — source de vérité projection
- `Packages/ProRangeKit/Sources/PRCore/ReferenceRasterizer.swift` — source de vérité raster CPU
- `.github/workflows/build.yml` — CI GitHub Actions (XcodeGen + macos-15)

---

*Document vivant — mis à jour à chaque phase.*