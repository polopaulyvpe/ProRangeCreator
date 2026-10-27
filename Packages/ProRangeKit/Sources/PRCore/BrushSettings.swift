import simd

/// Réglages d'un outil de peinture (pinceau ou gomme), organisés comme les sections de l'Atelier de pinceaux.
public struct BrushSettings: Equatable, Sendable {
    // MARK: À propos
    public var name = "Pinceau"
    public var author = ""

    // MARK: Taille et opacité courantes (curseurs latéraux)
    /// Rayon maximal (pression pleine), en degrés sur la sphère.
    public var radiusDegrees: Double
    /// Opacité maximale, dans [0, 1].
    public var opacity: Double
    public var hardness: Double

    // MARK: Trait
    /// Espacement entre dabs, en fraction du rayon courant.
    public var spacing: Double
    /// Variations aléatoires à chaque dab (0 = aucune).
    /// Espacement : ± cette fraction de l'espacement.
    public var spacingJitter: Double = 0
    /// Dispersion latérale, en fraction du diamètre, de part et d'autre du trait.
    public var scatter: Double = 0

    // MARK: Effilement (début du trait)
    /// Longueur de l'effilement, en diamètres de pinceau (0 = aucun).
    public var taperStartLength: Double = 0
    /// Réduction de taille tout au début du trait, dans [0, 1].
    public var taperSize: Double = 0
    /// Réduction d'opacité tout au début du trait, dans [0, 1].
    public var taperOpacity: Double = 0

    // MARK: Forme
    /// Forme du dab (nil = rond, avec la dureté).
    public var shape: BrushTexture?
    /// Angle de la forme, en degrés.
    public var shapeRotationDegrees: Double = 0
    /// La forme suit la direction du trait (l'angle s'y ajoute) ; sinon elle reste alignée sur l'est local.
    public var followStroke: Bool = false
    /// Rotation de la forme : ± cet angle, en radians (π = rotation entièrement aléatoire).
    public var rotationJitter: Double = 0
    /// Angle de départ tiré au hasard à chaque trait.
    public var randomizeRotation = false
    /// Forme retournée au hasard (miroir).
    public var randomFlip = false
    /// Rondeur de la forme : 1 = telle quelle, moins = écrasée.
    public var shapeRoundness: Double = 1
    /// Nombre de tampons posés à chaque dab (1 à 16), et sa variation (jusqu'à cette fraction en moins).
    public var stampCount = 1
    public var stampCountJitter: Double = 0

    // MARK: Grain
    /// Grain effectivement utilisé (dérivé de `grainSource` et des réglages de contraste, luminosité, inversion).
    public var grain: BrushTexture?
    /// Image du grain telle qu'importée.
    public var grainSource: BrushTexture?
    /// Mobile : le grain suit chaque tampon ; sinon texturé, fixé à la sphère.
    public var grainMoving = false
    /// Taille angulaire d'un motif de grain, en degrés.
    public var grainScaleDegrees: Double = 3
    public var grainRotationDegrees: Double = 0
    /// Profondeur du grain dans [0, 1], son minimum à pression nulle et sa variation par tampon.
    public var grainDepth: Double = 1
    public var grainDepthMinimum: Double = 0
    public var grainDepthJitter: Double = 0
    /// Décalage du grain tiré au hasard à chaque trait.
    public var grainOffsetJitter = false
    public var grainContrast: Double = 0
    public var grainBrightness: Double = 0
    public var grainInverted = false

    // MARK: Dynamique
    /// Taille et opacité réduites (ou augmentées si négatif) quand le trait va vite.
    public var speedSize: Double = 0
    public var speedOpacity: Double = 0
    /// Taille : jusqu'à cette fraction en moins, au hasard.
    public var sizeJitter: Double = 0
    /// Opacité : jusqu'à cette fraction en moins, au hasard.
    public var opacityJitter: Double = 0

    // MARK: Apple Pencil
    /// La pression fait varier la taille…
    public var pressureAffectsSize: Bool
    /// … et/ou l'opacité.
    public var pressureAffectsOpacity: Bool
    /// Intensité de ces effets, dans [0, 1].
    public var pressureSizeAmount: Double = 1
    public var pressureOpacityAmount: Double = 1
    /// Taille à pression nulle, en fraction du rayon maximal.
    public var minimumSize: Double
    /// Inclinaison du Pencil au-delà de `tiltAngleDegrees` (depuis la verticale) : opacité réduite, taille augmentée.
    public var tiltOpacity: Double = 0
    public var tiltSize: Double = 0
    public var tiltAngleDegrees: Double = 30

    // MARK: Propriétés
    /// Bornes des curseurs latéraux.
    public var maxSizeDegrees: Double = 30
    public var minSizeDegrees: Double = 0.3
    public var maxOpacity: Double = 1
    public var minOpacity: Double = 0.02

    public var hasJitter: Bool {
        spacingJitter > 0 || scatter > 0 || sizeJitter > 0 || opacityJitter > 0 || rotationJitter > 0 || randomFlip
            || stampCountJitter > 0 || grainDepthJitter > 0
    }

    public init(radiusDegrees: Double = 2, opacity: Double = 1, hardness: Double = 0.8, spacing: Double = 0.15,
                pressureAffectsSize: Bool = true, pressureAffectsOpacity: Bool = false, minimumSize: Double = 0.15) {
        self.radiusDegrees = radiusDegrees
        self.opacity = opacity
        self.hardness = hardness
        self.spacing = spacing
        self.pressureAffectsSize = pressureAffectsSize
        self.pressureAffectsOpacity = pressureAffectsOpacity
        self.minimumSize = minimumSize
    }

    public static let defaultBrush = BrushSettings()
    public static let defaultEraser = BrushSettings(radiusDegrees: 4, hardness: 0.6, pressureAffectsSize: true)

    /// Rayon en radians pour une pression dans [0, 1] (1 au doigt, qui n'a pas de pression).
    public func radius(pressure: Double) -> Double {
        radiusDegrees * pressureSizeScale(pressure) * .pi / 180
    }

    public func opacity(pressure: Double) -> Double {
        opacity * pressureOpacityScale(pressure)
    }

    func pressureSizeScale(_ pressure: Double) -> Double {
        guard pressureAffectsSize else { return 1 }
        let p = min(1, max(0, pressure))
        let full = minimumSize + (1 - minimumSize) * p
        return 1 - min(1, max(0, pressureSizeAmount)) * (1 - full)
    }

    func pressureOpacityScale(_ pressure: Double) -> Double {
        guard pressureAffectsOpacity else { return 1 }
        let p = min(1, max(0, pressure))
        return 1 - min(1, max(0, pressureOpacityAmount)) * (1 - p)
    }

    /// Nombre de tampons de ce dab, avec sa variation.
    public func stampCount(random: Double) -> Int {
        let n = max(1, min(16, stampCount))
        return max(1, Int((Double(n) * (1 - min(1, max(0, stampCountJitter)) * random)).rounded()))
    }

    /// Dab pour un point du trait.
    /// `strokeAngle` : direction du trait dans le plan tangent (radians depuis l'est local), pour les formes qui la suivent.
    /// `random` : tirages du dab (voir `DabRandom`) ; `.none` = aucune variation.
    /// `context` : longueur parcourue, vitesse, inclinaison et tirages du trait (`StrokeContext.none` = aucun effet).
    public func dab(at center: Vec3, pressure: Double, color: SIMD3<Float>, mode: DabMode, strokeAngle: Double = 0,
                    random: DabRandom = .none, context: StrokeContext = .none) -> SphericalDab {
        var sizeScale = pressureSizeScale(pressure) * (1 - min(1, max(0, sizeJitter)) * random.size)
        var alphaScale = pressureOpacityScale(pressure) * (1 - min(1, max(0, opacityJitter)) * random.opacity)
        // Effilement : de (1 − réduction) à 1 sur la longueur choisie, depuis le début du trait.
        if taperStartLength > 0 {
            let length = taperStartLength * 2 * radiusDegrees * .pi / 180
            let t = min(1, context.distance / max(length, 1e-9))
            sizeScale *= 1 - min(1, max(0, taperSize)) * (1 - t)
            alphaScale *= 1 - min(1, max(0, taperOpacity)) * (1 - t)
        }
        // Vitesse : pleine à 3 radians par seconde (un geste rapide).
        let fast = min(1, context.speed / 3)
        sizeScale *= max(0.05, 1 - speedSize * fast)
        alphaScale *= max(0, 1 - speedOpacity * fast)
        // Inclinaison au-delà du seuil.
        let threshold = min(89, max(0, tiltAngleDegrees))
        let tilted = min(1, max(0, (context.tilt * 90 - threshold) / (90 - threshold)))
        sizeScale *= 1 + tiltSize * tilted
        alphaScale *= max(0, 1 - tiltOpacity * tilted)

        let size = max(radiusDegrees * .pi / 180 * sizeScale, 1e-5)
        let alpha = min(1, max(0, opacity * alphaScale))
        var position = center
        if scatter > 0 {
            // Décalage perpendiculaire au trait, dans le plan tangent.
            let offset = scatter * 2 * size * (random.scatter * 2 - 1)
            let across = strokeAngle + .pi / 2
            position = TangentFrame(center: center).unproject([cos(across) * offset, sin(across) * offset])
        }
        var tip: DabTip?
        if shape != nil || grain != nil {
            var rotation = shapeRotationDegrees * .pi / 180 + (followStroke ? strokeAngle : 0) + rotationJitter * (random.rotation * 2 - 1)
            if randomizeRotation { rotation += context.rotationOffset }
            var depth = min(1, max(0, grainDepth))
            if grainDepthMinimum > 0 {
                let p = min(1, max(0, pressure))
                depth = grainDepthMinimum + (depth - grainDepthMinimum) * p
            }
            depth *= 1 - min(1, max(0, grainDepthJitter)) * random.depth
            tip = DabTip(shape: shape, grain: grain, rotation: rotation,
                         grainScale: max(0.05, grainScaleDegrees) * .pi / 180, grainDepth: depth,
                         flipX: randomFlip && random.flip, roundness: min(1, max(0.05, shapeRoundness)),
                         grainMoving: grainMoving, grainRotation: grainRotationDegrees * .pi / 180,
                         grainOffset: grainOffsetJitter ? context.grainOffset : .zero)
        }
        return SphericalDab(center: position, radius: size, hardness: hardness,
                            color: SIMD4<Float>(color.x, color.y, color.z, Float(alpha)), mode: mode, tip: tip)
    }

    /// Espacement du prochain dab, avec sa variation.
    public func spacing(radius: Double, random: Double) -> Double {
        max(radius * spacing * (1 + min(1, max(0, spacingJitter)) * (random * 2 - 1)), 1e-4)
    }

    /// Recalcule le grain utilisé à partir de l'image importée et des réglages de contraste, luminosité, inversion.
    public mutating func refreshGrain() {
        guard let source = grainSource else { return }
        if grainContrast == 0, grainBrightness == 0, !grainInverted {
            grain = source
            return
        }
        let gain = Float(1 + max(-0.95, min(1, grainContrast)))
        let lift = Float(max(-1, min(1, grainBrightness)))
        let values = source.values.map { v -> Float in
            let w = grainInverted ? 1 - v : v
            return min(1, max(0, 0.5 + (w - 0.5) * gain + lift))
        }
        grain = BrushTexture(name: source.name, size: source.size, values: values)
    }

    /// Angle du trait au point `center`, venant de `previous`, dans le plan tangent (radians depuis l'est local).
    public static func strokeAngle(from previous: Vec3, to center: Vec3) -> Double {
        let p = TangentFrame(center: center).project(previous)
        guard simd_length(p) > 1e-12 else { return 0 }
        return atan2(-p.y, -p.x)
    }
}

/// Ce que le trait sait au moment d'un dab : longueur parcourue, vitesse, inclinaison du Pencil, tirages du trait.
public struct StrokeContext: Sendable, Equatable {
    /// Longueur parcourue depuis le début du trait, en radians sur la sphère.
    public var distance: Double
    /// Vitesse du trait, en radians par seconde.
    public var speed: Double
    /// Inclinaison du Pencil : 0 = vertical, 1 = à plat.
    public var tilt: Double
    /// Décalage du grain et angle de départ de la forme, tirés une fois par trait.
    public var grainOffset: SIMD2<Double>
    public var rotationOffset: Double

    public init(distance: Double = .infinity, speed: Double = 0, tilt: Double = 0, grainOffset: SIMD2<Double> = .zero,
                rotationOffset: Double = 0) {
        self.distance = distance
        self.speed = speed
        self.tilt = tilt
        self.grainOffset = grainOffset
        self.rotationOffset = rotationOffset
    }

    /// Aucun effet (trait déjà bien engagé, immobile, Pencil vertical).
    public static let none = StrokeContext()
}

/// Tirages aléatoires d'un dab, dans [0, 1) (rotation et dispersion centrées sur 0,5).
public struct DabRandom: Sendable, Equatable {
    public var size: Double
    public var opacity: Double
    public var rotation: Double
    public var scatter: Double
    public var flip: Bool
    /// Variation de la profondeur du grain.
    public var depth: Double = 0

    public init(size: Double, opacity: Double, rotation: Double, scatter: Double, flip: Bool) {
        self.size = size
        self.opacity = opacity
        self.rotation = rotation
        self.scatter = scatter
        self.flip = flip
    }

    /// Aucune variation.
    public static let none = DabRandom(size: 0, opacity: 0, rotation: 0.5, scatter: 0.5, flip: false)
}

/// Générateur pseudo-aléatoire reproductible (SplitMix64) : un trait rejoué donne les mêmes variations.
public struct StrokeRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    public mutating func dab() -> DabRandom {
        var random = DabRandom(size: next(), opacity: next(), rotation: next(), scatter: next(), flip: next() < 0.5)
        random.depth = next()
        return random
    }
}
