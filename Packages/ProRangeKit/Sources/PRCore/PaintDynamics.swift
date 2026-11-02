import simd

/// Tirages de couleur d'un tampon ou d'un trait, dans [0, 1) : teinte et saturation centrées sur 0,5, les autres à 0 = aucun effet.
public struct ColorDraw: Sendable, Equatable {
    public var hue: Double
    public var saturation: Double
    public var lightness: Double
    public var darkness: Double
    public var secondary: Double

    public init(hue: Double = 0.5, saturation: Double = 0.5, lightness: Double = 0, darkness: Double = 0, secondary: Double = 0) {
        self.hue = hue
        self.saturation = saturation
        self.lightness = lightness
        self.darkness = darkness
        self.secondary = secondary
    }

    /// Aucune variation.
    public static let none = ColorDraw()
}

/// Dynamique de couleur (Atelier > Dynamique de couleur), d'après la description du manuel de Procreate ; les formules
/// sont les nôtres. Calculée en HSB sur les valeurs encodées sRGB (comme le sélecteur), la couleur rendue reste linéaire.
/// - variation par tampon et par trait : teinte ± la moitié du cercle à 100 %, saturation ± réglage, éclaircir vers le
///   blanc, assombrir vers le noir, couleur secondaire mélangée au hasard ;
/// - pression et inclinaison : teinte décalée jusqu'à un tour complet, saturation du blanc (légère) à la couleur (forte),
///   luminosité du clair (légère) au sombre (forte), passage progressif vers la couleur secondaire.
public enum ColorDynamics {
    /// `color` et `secondary` en RGB linéaire. `pressure` (après la courbe) et `tilt` (au-delà du seuil) dans [0, 1].
    public static func apply(_ color: SIMD3<Float>, secondary: SIMD3<Float>, brush s: BrushSettings, stamp: ColorDraw,
                             stroke: ColorDraw, pressure: Double, tilt: Double) -> SIMD3<Float> {
        func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
        var rgb = SIMD3<Double>(ColorTransfer.toEncoded(color))
        let second = SIMD3<Double>(ColorTransfer.toEncoded(secondary))
        // Couleur secondaire d'abord (pression, inclinaison, tirages) : les variations HSB s'appliquent au mélange.
        let toSecondary = clamp01(s.pressureSecondary * pressure + s.tiltSecondary * tilt
                                  + s.strokeSecondaryJitter * stroke.secondary + s.stampSecondaryJitter * stamp.secondary)
        rgb += (second - rgb) * toSecondary
        var hsb = HSBColor(rgb: rgb.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1)))
        hsb.hue += s.pressureHue * pressure + s.tiltHue * tilt
            + 0.5 * s.strokeHueJitter * (stroke.hue * 2 - 1) + 0.5 * s.stampHueJitter * (stamp.hue * 2 - 1)
        hsb.hue -= hsb.hue.rounded(.down)
        var saturation = hsb.saturation
        saturation += s.strokeSaturationJitter * (stroke.saturation * 2 - 1) + s.stampSaturationJitter * (stamp.saturation * 2 - 1)
        saturation *= 1 - clamp01(s.pressureSaturation) * (1 - pressure)
        saturation *= 1 - clamp01(s.tiltSaturation) * tilt
        hsb.saturation = clamp01(saturation)
        // Luminosité : 0,5 de pression = inchangée ; légère → plus clair, forte → plus sombre.
        let brightnessShift = s.pressureBrightness * (0.5 - pressure) * 2 + s.tiltBrightness * tilt
        if brightnessShift != 0 { hsb.brightness = clamp01(hsb.brightness * (1 - max(0, -brightnessShift))) }
        var out = hsb.rgb
        if brightnessShift > 0 { out += (SIMD3(repeating: 1) - out) * min(1, brightnessShift) }
        let lighter = clamp01(s.strokeLightnessJitter * stroke.lightness + s.stampLightnessJitter * stamp.lightness)
        out += (SIMD3(repeating: 1) - out) * lighter
        let darker = clamp01(s.strokeDarknessJitter * stroke.darkness + s.stampDarknessJitter * stamp.darkness)
        out *= 1 - darker
        return ColorTransfer.toLinear(SIMD3<Float>(out))
    }
}

/// Mélange humide (Atelier > Mélange humide) : le pinceau porte une réserve de peinture qui se mélange à celle de la toile.
/// Le manuel de Procreate décrit les réglages, pas les formules : celles-ci sont les nôtres, à régler sur l'iPad.
/// - Dilution : part d'eau. Le dépôt devient transparent et prend la couleur de la toile.
/// - Charge : peinture chargée au départ. Le pinceau se vide le long du trait, d'autant plus vite qu'il est dilué ;
///   lever le stylet le recharge (un mélangeur neuf par trait).
/// - Attaque : quantité de peinture qui adhère à la toile.
/// - Tirage : la réserve prend la couleur de la toile sous le pinceau (et la traîne plus loin).
/// - Flou : le dépôt prend la couleur moyenne d'une zone plus large (la toile s'adoucit sous le trait), variable par tampon.
/// - Variation d'humidité : dilution tirée au hasard à chaque tampon.
/// La toile lue est celle d'avant le trait (le calque du CPU) : le trait ne reprend pas sa propre peinture.
public struct WetMixer: Sendable {
    /// Couleur de la réserve (RGB linéaire), nil avant le premier tampon.
    public private(set) var reservoir: SIMD3<Float>?

    public init() {}

    /// Applique le mélange au tampon `dab` (couleur de pinceau dans `dab.color`). `pickup` : couleur moyenne de la toile
    /// sous le tampon, `wide` : sur une zone plus large (pour le flou), toutes deux RGBA linéaires prémultipliées.
    /// `distance` : longueur du trait parcourue, en radians.
    public mutating func apply(_ dab: inout SphericalDab, brush s: BrushSettings, distance: Double,
                               pickup: SIMD4<Float>, wide: SIMD4<Float>, random: DabRandom) {
        let brushColor = SIMD3<Float>(dab.color.x, dab.color.y, dab.color.z)
        var paint = reservoir ?? brushColor
        let wetJitter = min(1, max(0, s.wetnessJitter)) * (random.wet * 2 - 1)
        let water = Float(min(1, max(0, s.wetDilution * (1 + wetJitter))))
        let canvasAlpha = min(1, max(0, pickup.w))
        let canvas = canvasAlpha > 1e-4 ? SIMD3<Float>(pickup.x, pickup.y, pickup.z) / pickup.w : paint
        let pull = Float(min(1, max(0, s.wetPull)))
        // La réserve prend la couleur de la toile (tirage), un peu plus quand le pinceau est mouillé.
        paint += (canvas - paint) * min(1, pull * canvasAlpha * (0.35 + 0.4 * water))
        reservoir = paint
        // Dépôt : l'eau emporte la couleur de la toile, le flou celle d'une zone plus large.
        var deposit = paint + (canvas - paint) * (water * canvasAlpha * 0.6)
        let blur = Float(min(1, max(0, s.wetBlur * (1 - min(1, max(0, s.wetBlurJitter)) * random.blur))))
        if blur > 0, wide.w > 1e-4 {
            let around = SIMD3<Float>(wide.x, wide.y, wide.z) / wide.w
            deposit += (around - deposit) * (blur * min(1, wide.w))
        }
        // Charge : le pinceau se vide sur une longueur qui dépend de la charge et de la dilution (en diamètres).
        let diameter = max(2 * dab.radius, 1e-6)
        let charge = min(1, max(0, s.wetCharge))
        let run = (1 + 40 * charge * charge) / max(0.1, Double(water))
        let load = Float(exp(-distance / (diameter * run)))
        let attack = Float(0.3 + 0.7 * min(1, max(0, s.wetAttack)))
        var alpha = dab.color.w * load * (1 - 0.75 * water) * attack
        // Le tirage traîne la peinture de la toile même quand le pinceau est vide.
        alpha += (1 - alpha) * pull * canvasAlpha * 0.5 * Float(1 - load * 0.5)
        dab.color = SIMD4<Float>(deposit.x, deposit.y, deposit.z, min(1, max(0, alpha)))
    }
}

extension BrushSettings {
    /// Le pinceau varie sa couleur (dynamique de couleur).
    public var hasColorDynamics: Bool {
        [stampHueJitter, stampSaturationJitter, stampLightnessJitter, stampDarknessJitter, stampSecondaryJitter,
         strokeHueJitter, strokeSaturationJitter, strokeLightnessJitter, strokeDarknessJitter, strokeSecondaryJitter,
         pressureHue, pressureSaturation, pressureBrightness, pressureSecondary,
         tiltHue, tiltSaturation, tiltBrightness, tiltSecondary].contains { $0 != 0 }
    }

    /// Le mélange humide a un effet : comme dans Procreate, il faut de l'eau (dilution) ou du flou. Sans dilution, charge,
    /// attaque, tirage et grade n'agissent pas (Minke : charge 1 %, tirage 10 %, dilution nulle, trait plein).
    public var wetMixActive: Bool { wetDilution > 0 || wetBlur > 0 }

    /// La couleur change d'un tampon à l'autre : le trait garde une couleur par texel (voir `StrokeMask.depositColor`).
    public var varyingColor: Bool { hasColorDynamics || wetMixActive }
}
