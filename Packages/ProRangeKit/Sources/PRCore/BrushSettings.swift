import simd

/// Réglages d'un outil de peinture (pinceau ou gomme) et dynamique de pression.
public struct BrushSettings: Equatable, Sendable {
    /// Rayon maximal (pression pleine), en degrés sur la sphère.
    public var radiusDegrees: Double
    /// Opacité maximale, dans [0, 1].
    public var opacity: Double
    public var hardness: Double
    /// Espacement entre dabs, en fraction du rayon courant.
    public var spacing: Double
    /// La pression fait varier la taille…
    public var pressureAffectsSize: Bool
    /// … et/ou l'opacité.
    public var pressureAffectsOpacity: Bool
    /// Taille à pression nulle, en fraction du rayon maximal.
    public var minimumSize: Double
    /// Forme du dab (nil = rond, avec la dureté).
    public var shape: BrushTexture?
    /// Grain fixé à la sphère (nil = aucun).
    public var grain: BrushTexture?
    /// Angle de la forme, en degrés.
    public var shapeRotationDegrees: Double = 0
    /// La forme suit la direction du trait (l'angle s'y ajoute) ; sinon elle reste alignée sur l'est local.
    public var followStroke: Bool = false
    /// Taille angulaire d'un motif de grain, en degrés.
    public var grainScaleDegrees: Double = 3
    /// Profondeur du grain dans [0, 1].
    public var grainDepth: Double = 1
    /// Variations aléatoires à chaque dab (0 = aucune), comme la « dynamique » de Procreate.
    /// Espacement : ± cette fraction de l'espacement.
    public var spacingJitter: Double = 0
    /// Dispersion latérale, en fraction du diamètre, de part et d'autre du trait.
    public var scatter: Double = 0
    /// Taille : jusqu'à cette fraction en moins.
    public var sizeJitter: Double = 0
    /// Opacité : jusqu'à cette fraction en moins.
    public var opacityJitter: Double = 0
    /// Rotation de la forme : ± cet angle, en radians (π = rotation entièrement aléatoire).
    public var rotationJitter: Double = 0
    /// Forme retournée au hasard (miroir).
    public var randomFlip = false

    public var hasJitter: Bool {
        spacingJitter > 0 || scatter > 0 || sizeJitter > 0 || opacityJitter > 0 || rotationJitter > 0 || randomFlip
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
        let p = min(1, max(0, pressure))
        let scale = pressureAffectsSize ? minimumSize + (1 - minimumSize) * p : 1
        return radiusDegrees * scale * .pi / 180
    }

    public func opacity(pressure: Double) -> Double {
        let p = min(1, max(0, pressure))
        return pressureAffectsOpacity ? opacity * p : opacity
    }

    /// Dab pour un point du trait.
    /// `strokeAngle` : direction du trait dans le plan tangent (radians depuis l'est local), pour les formes qui la suivent.
    /// `random` : tirages du dab (voir `DabRandom`) ; `.none` = aucune variation.
    public func dab(at center: Vec3, pressure: Double, color: SIMD3<Float>, mode: DabMode, strokeAngle: Double = 0,
                    random: DabRandom = .none) -> SphericalDab {
        let size = max(radius(pressure: pressure) * (1 - min(1, max(0, sizeJitter)) * random.size), 1e-5)
        let alpha = opacity(pressure: pressure) * (1 - min(1, max(0, opacityJitter)) * random.opacity)
        var position = center
        if scatter > 0 {
            // Décalage perpendiculaire au trait, dans le plan tangent.
            let offset = scatter * 2 * size * (random.scatter * 2 - 1)
            let across = strokeAngle + .pi / 2
            position = TangentFrame(center: center).unproject([cos(across) * offset, sin(across) * offset])
        }
        var tip: DabTip?
        if shape != nil || grain != nil {
            let rotation = shapeRotationDegrees * .pi / 180 + (followStroke ? strokeAngle : 0) + rotationJitter * (random.rotation * 2 - 1)
            tip = DabTip(shape: shape, grain: grain, rotation: rotation,
                         grainScale: max(0.05, grainScaleDegrees) * .pi / 180, grainDepth: min(1, max(0, grainDepth)),
                         flipX: randomFlip && random.flip)
        }
        return SphericalDab(center: position, radius: size, hardness: hardness,
                            color: SIMD4<Float>(color.x, color.y, color.z, Float(alpha)), mode: mode, tip: tip)
    }

    /// Espacement du prochain dab, avec sa variation.
    public func spacing(radius: Double, random: Double) -> Double {
        max(radius * spacing * (1 + min(1, max(0, spacingJitter)) * (random * 2 - 1)), 1e-4)
    }

    /// Angle du trait au point `center`, venant de `previous`, dans le plan tangent (radians depuis l'est local).
    public static func strokeAngle(from previous: Vec3, to center: Vec3) -> Double {
        let p = TangentFrame(center: center).project(previous)
        guard simd_length(p) > 1e-12 else { return 0 }
        return atan2(-p.y, -p.x)
    }
}

/// Tirages aléatoires d'un dab, dans [0, 1) (rotation et dispersion centrées sur 0,5).
public struct DabRandom: Sendable, Equatable {
    public var size: Double
    public var opacity: Double
    public var rotation: Double
    public var scatter: Double
    public var flip: Bool

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
        DabRandom(size: next(), opacity: next(), rotation: next(), scatter: next(), flip: next() < 0.5)
    }
}
