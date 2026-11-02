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
    /// Variation linéaire : décalage le long du trait, en fraction du diamètre, en avant ou en arrière.
    public var longitudinalJitter: Double = 0

    // MARK: Stabilisation (voir `StrokeStabilizer`), chacune dans [0, 1]
    public var streamLine: Double = 0
    public var stabilization: Double = 0
    public var motionFiltering: Double = 0
    public var pressureSmoothing: Double = 0

    public var stabilizer: StrokeStabilizer.Settings {
        StrokeStabilizer.Settings(streamLine: streamLine, stabilization: stabilization,
                                  motionFiltering: motionFiltering, pressureSmoothing: pressureSmoothing)
    }

    // MARK: Effilement (début du trait)
    /// Longueur de l'effilement, en diamètres de pinceau (0 = aucun).
    public var taperStartLength: Double = 0
    /// Réduction de taille tout au début du trait, dans [0, 1].
    public var taperSize: Double = 0
    /// Réduction d'opacité tout au début du trait, dans [0, 1].
    public var taperOpacity: Double = 0
    /// Effilement de fin de trait, en diamètres (0 = aucun) : appliqué au lever du stylet, le trait est alors repeint
    /// avec sa fin affinée (même taille et opacité que le début).
    public var taperEndLength: Double = 0

    /// Facteurs de taille et d'opacité de l'effilement de fin pour un dab à `remaining` radians de la fin du trait.
    public func endTaper(remaining: Double) -> (size: Double, opacity: Double) {
        guard taperEndLength > 0 else { return (1, 1) }
        let length = taperEndLength * 2 * radiusDegrees * .pi / 180
        let t = min(1, max(0, remaining) / max(length, 1e-9))
        return (1 - min(1, max(0, taperSize)) * (1 - t), 1 - min(1, max(0, taperOpacity)) * (1 - t))
    }

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
    /// Variation de rondeur verticale et horizontale : la forme est écrasée au hasard, jusqu'à cette fraction, à chaque tampon.
    public var roundnessJitter: Double = 0
    public var roundnessJitterX: Double = 0
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
    /// Mode de fusion du grain avec la forme (produit = classique ; densité linéaire + = le grain creuse la forme).
    public var grainBlendMode: DualBlendMode = .multiply
    /// Grain mobile : 0 = collé à chaque tampon (glisse), 1 = rouleau (il défile le long du trait, comme fixé au papier).
    public var grainMovement: Double = 0

    // MARK: Dynamique de couleur (voir `ColorDynamics`), chacune dans [0, 1]
    /// Variation par tampon : teinte, saturation, éclaircir, assombrir, couleur secondaire.
    public var stampHueJitter: Double = 0
    public var stampSaturationJitter: Double = 0
    public var stampLightnessJitter: Double = 0
    public var stampDarknessJitter: Double = 0
    public var stampSecondaryJitter: Double = 0
    /// Variation tirée une fois par trait.
    public var strokeHueJitter: Double = 0
    public var strokeSaturationJitter: Double = 0
    public var strokeLightnessJitter: Double = 0
    public var strokeDarknessJitter: Double = 0
    public var strokeSecondaryJitter: Double = 0
    /// Couleur selon la pression.
    public var pressureHue: Double = 0
    public var pressureSaturation: Double = 0
    public var pressureBrightness: Double = 0
    public var pressureSecondary: Double = 0
    /// Couleur selon l'inclinaison (au-delà du seuil d'inclinaison).
    public var tiltHue: Double = 0
    public var tiltSaturation: Double = 0
    public var tiltBrightness: Double = 0
    public var tiltSecondary: Double = 0

    // MARK: Mélange humide (voir `WetMixer`)
    public var wetDilution: Double = 0
    public var wetCharge: Double = 1
    public var wetAttack: Double = 0
    public var wetPull: Double = 0
    public var wetGrade: Double = 0
    public var wetBlur: Double = 0
    public var wetBlurJitter: Double = 0
    public var wetnessJitter: Double = 0

    // MARK: Rendu (voir `BrushRendering` et `StrokeMask`)
    public var rendering: BrushRendering = .lightGlaze
    /// Mode de fusion Multiplier : la peinture fonce celle déjà posée au lieu de la couvrir (Minke).
    public var multiplyBlend = false
    /// Flux, dans [0, 1] : part de l'opacité ajoutée au trait à chaque tampon (1 = d'un coup, moins = monte progressivement).
    public var flow: Double = 1

    // MARK: Pinceau double
    /// Pinceau secondaire (0 ou 1 élément ; un tableau pour que la structure puisse se contenir elle-même).
    public var secondaryBrushes: [BrushSettings] = []
    /// Combinaison des couvertures du principal et du secondaire.
    public var dualBlendMode: DualBlendMode = .multiply
    /// Taille du secondaire par rapport au principal : elle le suit quand on change la taille.
    public var secondaryScale: Double = 1

    public var secondary: BrushSettings? {
        get { secondaryBrushes.first }
        set { secondaryBrushes = newValue.map { [$0] } ?? [] }
    }

    /// Pinceau secondaire prêt à peindre (taille suivant celle du principal), nil pour un pinceau simple.
    public var resolvedSecondary: BrushSettings? {
        guard var s = secondary else { return nil }
        s.radiusDegrees = radiusDegrees * secondaryScale
        s.secondaryBrushes = []
        return s
    }

    /// Façon de poser le trait de ce pinceau.
    public func strokeStyle(color: SIMD3<Float>, mode: DabMode) -> StrokeStyle {
        StrokeStyle(color: color, mode: mode, capsPrimary: rendering.capsOpacity,
                    capsSecondary: secondary?.rendering.capsOpacity ?? true, dual: secondary == nil ? nil : dualBlendMode,
                    varyingColor: mode == .paint && varyingColor, multiply: mode == .paint && multiplyBlend)
    }

    // MARK: Dynamique
    /// Taille et opacité réduites (ou augmentées si négatif) quand le trait va vite.
    public var speedSize: Double = 0
    public var speedOpacity: Double = 0
    /// Espacement augmenté quand le trait va vite.
    public var speedSpacing: Double = 0
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
    /// La pression fait varier le flux, de cette intensité (0 = non).
    public var pressureFlowAmount: Double = 0
    /// Courbe de pression du pinceau (appliquée d'abord), puis courbes propres à la taille, à l'opacité et au flux.
    public var pressureCurve = PressureCurve.linear
    public var sizePressureCurve = PressureCurve.linear
    public var opacityPressureCurve = PressureCurve.linear
    public var flowPressureCurve = PressureCurve.linear
    /// Taille à pression nulle, en fraction du rayon maximal.
    public var minimumSize: Double
    /// Inclinaison du Pencil au-delà de `tiltAngleDegrees` (depuis la verticale) : opacité réduite, taille augmentée.
    public var tiltOpacity: Double = 0
    public var tiltSize: Double = 0
    public var tiltAngleDegrees: Double = 30
    /// Azimut : la forme tourne avec la direction du Pencil (remplace la rotation suivant le trait ; sans effet au doigt).
    public var azimuthRotation = false
    /// Rondeur de la forme selon la pression (légère = écrasée) et l'inclinaison (couchée = écrasée), dans [0, 1].
    public var pressureRoundness: Double = 0
    public var tiltRoundness: Double = 0
    /// Bavure : bord adouci et grain plus marqué à pression légère, ou quand le Pencil est incliné, dans [0, 1].
    public var pressureBleed: Double = 0
    public var tiltBleed: Double = 0
    /// Dégradé : le bord s'adoucit quand le Pencil est incliné (ombrage sur le côté de la mine), dans [0, 1].
    public var tiltGradation: Double = 0

    // MARK: Propriétés
    /// Bornes des curseurs latéraux.
    public var maxSizeDegrees: Double = 30
    public var minSizeDegrees: Double = 0.3
    public var maxOpacity: Double = 1
    public var minOpacity: Double = 0.02

    public var hasJitter: Bool {
        spacingJitter > 0 || scatter > 0 || longitudinalJitter > 0 || sizeJitter > 0 || opacityJitter > 0 || rotationJitter > 0 || randomFlip
            || stampCountJitter > 0 || grainDepthJitter > 0 || roundnessJitter > 0 || roundnessJitterX > 0
            || hasColorDynamics || (wetMixActive && (wetnessJitter > 0 || wetBlurJitter > 0))
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

    /// Pression après la courbe du pinceau.
    func curvedPressure(_ pressure: Double) -> Double {
        pressureCurve.value(min(1, max(0, pressure)))
    }

    func pressureSizeScale(_ pressure: Double) -> Double {
        guard pressureAffectsSize else { return 1 }
        let p = sizePressureCurve.value(curvedPressure(pressure))
        let full = minimumSize + (1 - minimumSize) * p
        return 1 - min(1, max(0, pressureSizeAmount)) * (1 - full)
    }

    func pressureOpacityScale(_ pressure: Double) -> Double {
        guard pressureAffectsOpacity else { return 1 }
        let p = opacityPressureCurve.value(curvedPressure(pressure))
        return 1 - min(1, max(0, pressureOpacityAmount)) * (1 - p)
    }

    /// Flux d'un tampon pour cette pression (rendu et pression compris).
    public func flow(pressure: Double) -> Double {
        var f = rendering.flow(min(1, max(0, self.flow)))
        if pressureFlowAmount > 0, !rendering.uniformFlow {
            let p = flowPressureCurve.value(curvedPressure(pressure))
            f *= 1 - min(1, pressureFlowAmount) * (1 - p)
        }
        return f
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
        let curved = curvedPressure(pressure)
        // Bavure et dégradé : bord adouci (et grain plus marqué) à pression légère ou Pencil incliné.
        let bleed = min(1, max(0, pressureBleed) * (1 - curved) + max(0, tiltBleed) * tilted)
        let softness = min(1, bleed + max(0, tiltGradation) * tilted)
        let edgeHardness = hardness * (1 - softness)
        var paint = color
        if hasColorDynamics {
            paint = ColorDynamics.apply(color, secondary: context.secondaryColor ?? color, brush: self, stamp: random.color,
                                        stroke: context.colorDraw, pressure: curved, tilt: tilted)
        }

        let size = max(radiusDegrees * .pi / 180 * sizeScale, 1e-5)
        let alpha = min(1, max(0, opacity * alphaScale))
        var position = center
        // Décalages dans le plan tangent : en travers du trait (dispersion latérale) et le long (variation linéaire).
        var shift = SIMD2<Double>.zero
        if scatter > 0 {
            let offset = scatter * 2 * size * (random.scatter * 2 - 1)
            let across = strokeAngle + .pi / 2
            shift += [cos(across) * offset, sin(across) * offset]
        }
        if longitudinalJitter > 0 {
            let offset = longitudinalJitter * 2 * size * (random.along * 2 - 1)
            shift += [cos(strokeAngle) * offset, sin(strokeAngle) * offset]
        }
        if shift != .zero { position = TangentFrame(center: center).unproject(shift) }
        var tip: DabTip?
        if shape != nil || grain != nil {
            // Azimut : la forme suit la direction du Pencil (au doigt, la rotation habituelle).
            let direction = azimuthRotation ? context.azimuth ?? (followStroke ? strokeAngle : 0) : (followStroke ? strokeAngle : 0)
            var rotation = shapeRotationDegrees * .pi / 180 + direction + rotationJitter * (random.rotation * 2 - 1)
            if randomizeRotation { rotation += context.rotationOffset }
            var depth = min(1, max(0, grainDepth))
            if grainDepthMinimum > 0 {
                depth = grainDepthMinimum + (depth - grainDepthMinimum) * curved
            }
            depth *= 1 - min(1, max(0, grainDepthJitter)) * random.depth
            depth += (1 - depth) * bleed
            // Grade (mélange humide) : texture plus contrastée.
            if wetMixActive { depth += (1 - depth) * min(1, max(0, wetGrade)) }
            let squash = (1 - min(1, max(0, pressureRoundness)) * (1 - curved)) * (1 - min(1, max(0, tiltRoundness)) * tilted)
            let grainScale = max(0.05, grainScaleDegrees) * .pi / 180
            let grainRotation = grainRotationDegrees * .pi / 180
            var grainOffset = grainOffsetJitter ? context.grainOffset : .zero
            if grainMoving, grainMovement > 0, context.distance.isFinite {
                // Rouleau : le grain avance avec le trait, dans le repère du grain (tourné comme lui), en motifs.
                let travel = min(1, grainMovement) * context.distance / grainScale
                let dx = cos(strokeAngle), dy = sin(strokeAngle)
                let c = cos(grainRotation), s = sin(grainRotation)
                grainOffset += [(dx * c + dy * s) * travel, (-dx * s + dy * c) * travel]
            }
            tip = DabTip(shape: shape, grain: grain, rotation: rotation, grainScale: grainScale, grainDepth: depth,
                         flipX: randomFlip && random.flip,
                         roundness: max(0.05, min(1, shapeRoundness) * (1 - min(1, max(0, roundnessJitter)) * random.roundY) * squash),
                         grainMoving: grainMoving, grainRotation: grainRotation, grainOffset: grainOffset,
                         grainBlend: grainBlendMode, width: max(0.05, 1 - min(1, max(0, roundnessJitterX)) * random.roundX))
        }
        var dab = SphericalDab(center: position, radius: size, hardness: edgeHardness,
                               color: SIMD4<Float>(paint.x, paint.y, paint.z, Float(alpha)), mode: mode, tip: tip)
        dab.flow = Float(flow(pressure: pressure))
        return dab
    }

    /// Espacement du prochain dab, avec sa variation ; `speed` (radians par seconde) l'augmente selon `speedSpacing`.
    public func spacing(radius: Double, random: Double, speed: Double = 0) -> Double {
        let fast = min(1, speed / 3)
        let base = radius * spacing * (1 + min(1, max(0, spacingJitter)) * (random * 2 - 1))
        return max(base * (1 + max(0, speedSpacing) * fast), 1e-4)
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
    /// Azimut du Pencil dans le plan tangent (radians depuis l'est local), nil au doigt.
    public var azimuth: Double?
    /// Tirages de couleur du trait et couleur secondaire (dynamique de couleur ; nil = la couleur du pinceau).
    public var colorDraw: ColorDraw
    public var secondaryColor: SIMD3<Float>?

    public init(distance: Double = .infinity, speed: Double = 0, tilt: Double = 0, grainOffset: SIMD2<Double> = .zero,
                rotationOffset: Double = 0, azimuth: Double? = nil, colorDraw: ColorDraw = .none,
                secondaryColor: SIMD3<Float>? = nil) {
        self.distance = distance
        self.speed = speed
        self.tilt = tilt
        self.grainOffset = grainOffset
        self.rotationOffset = rotationOffset
        self.azimuth = azimuth
        self.colorDraw = colorDraw
        self.secondaryColor = secondaryColor
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
    /// Variation linéaire (centrée sur 0,5).
    public var along: Double = 0.5
    /// Variations de rondeur verticale et horizontale.
    public var roundY: Double = 0
    public var roundX: Double = 0
    /// Dynamique de couleur par tampon.
    public var color = ColorDraw.none
    /// Mélange humide : humidité (centrée sur 0,5) et flou.
    public var wet: Double = 0.5
    public var blur: Double = 0

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
        random.along = next()
        random.roundY = next()
        random.roundX = next()
        random.color = colorDraw()
        random.wet = next()
        random.blur = next()
        return random
    }

    public mutating func colorDraw() -> ColorDraw {
        ColorDraw(hue: next(), saturation: next(), lightness: next(), darkness: next(), secondary: next())
    }
}
