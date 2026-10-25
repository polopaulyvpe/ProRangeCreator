import simd

/// Les 26 modes de fusion des calques (noms de Photoshop / Procreate).
/// Formules du W3C Compositing and Blending Level 1 (séparables et non séparables), calculées dans l'espace de fusion (D4).
///
/// Valeurs au-delà de 1 (HDR) :
/// - **non bornés** (`isBounded == false`) : Normal, Produit, Obscurcir, Éclaircir, Densité linéaire +, Ajout,
///   Soustraction, Division, Différence, Couleur plus foncée / plus claire ; les valeurs > 1 passent telles quelles
///   (résultat seulement borné à ≥ 0, et la Division plafonnée à 65 504, le maximum d'un demi-flottant) ;
/// - **bornés** : tous les autres ; leurs formules supposent [0, 1], donc les deux couleurs y sont écrêtées avant le calcul.
public enum BlendMode: String, CaseIterable, Codable, Sendable {
    case normal
    case multiply, darken, colorBurn, linearBurn, darkerColor
    case lighten, screen, colorDodge, add, lighterColor
    case overlay, softLight, hardLight, vividLight, linearLight, pinLight, hardMix
    case difference, exclusion, subtract, divide
    case hue, saturation, color, luminosity

    public var label: String {
        switch self {
        case .normal: "Normal"
        case .multiply: "Produit"
        case .darken: "Obscurcir"
        case .colorBurn: "Densité couleur +"
        case .linearBurn: "Densité linéaire +"
        case .darkerColor: "Couleur plus foncée"
        case .lighten: "Éclaircir"
        case .screen: "Superposition (écran)"
        case .colorDodge: "Densité couleur −"
        case .add: "Ajout (densité linéaire −)"
        case .lighterColor: "Couleur plus claire"
        case .overlay: "Incrustation"
        case .softLight: "Lumière tamisée"
        case .hardLight: "Lumière crue"
        case .vividLight: "Lumière vive"
        case .linearLight: "Lumière linéaire"
        case .pinLight: "Lumière ponctuelle"
        case .hardMix: "Mélange maximal"
        case .difference: "Différence"
        case .exclusion: "Exclusion"
        case .subtract: "Soustraction"
        case .divide: "Division"
        case .hue: "Teinte"
        case .saturation: "Saturation"
        case .color: "Couleur"
        case .luminosity: "Luminosité"
        }
    }

    /// Code partagé avec le shader (ordre de `allCases`).
    public var code: Int { Self.allCases.firstIndex(of: self)! }

    public var isBounded: Bool {
        switch self {
        case .normal, .multiply, .darken, .lighten, .linearBurn, .add, .subtract, .divide, .difference, .darkerColor, .lighterColor:
            false
        default:
            true
        }
    }

    /// B(b, s) : couleur mélangée, sur des couleurs droites (non prémultipliées) de l'espace de fusion.
    public func blend(_ backdrop: SIMD3<Float>, _ source: SIMD3<Float>) -> SIMD3<Float> {
        let b = isBounded ? simd_clamp(backdrop, .zero, .one) : backdrop
        let s = isBounded ? simd_clamp(source, .zero, .one) : source
        let result: SIMD3<Float>
        switch self {
        case .normal: result = s
        case .multiply: result = b * s
        case .darken: result = simd_min(b, s)
        case .lighten: result = simd_max(b, s)
        case .linearBurn: result = b + s - 1
        case .add: result = b + s
        case .subtract: result = b - s
        case .divide: result = Self.map(b, s) { b, s in s <= 1e-6 ? (b > 0 ? 65504 : 0) : min(65504, b / s) }
        case .difference: result = abs(b - s)
        case .darkerColor: result = Self.lum(s) < Self.lum(b) ? s : b
        case .lighterColor: result = Self.lum(s) > Self.lum(b) ? s : b
        case .screen: result = b + s - b * s
        case .colorBurn: result = Self.map(b, s, Self.colorBurn)
        case .colorDodge: result = Self.map(b, s, Self.colorDodge)
        case .overlay: result = Self.map(b, s) { b, s in Self.hardLight(s, b) }
        case .softLight: result = Self.map(b, s, Self.softLight)
        case .hardLight: result = Self.map(b, s, Self.hardLight)
        case .vividLight: result = Self.map(b, s) { b, s in s <= 0.5 ? Self.colorBurn(b, 2 * s) : Self.colorDodge(b, 2 * s - 1) }
        case .linearLight: result = simd_clamp(b + 2 * s - 1, .zero, .one)
        case .pinLight: result = Self.map(b, s) { b, s in s <= 0.5 ? min(b, 2 * s) : max(b, 2 * s - 1) }
        case .hardMix: result = Self.map(b, s) { b, s in b + s >= 1 ? 1 : 0 }
        case .exclusion: result = b + s - 2 * b * s
        case .hue: result = Self.setLum(Self.setSat(s, Self.sat(b)), Self.lum(b))
        case .saturation: result = Self.setLum(Self.setSat(b, Self.sat(s)), Self.lum(b))
        case .color: result = Self.setLum(s, Self.lum(b))
        case .luminosity: result = Self.setLum(b, Self.lum(s))
        }
        return simd_max(result, .zero)
    }

    // MARK: - Formules

    private static func map(_ b: SIMD3<Float>, _ s: SIMD3<Float>, _ f: (Float, Float) -> Float) -> SIMD3<Float> {
        [f(b.x, s.x), f(b.y, s.y), f(b.z, s.z)]
    }

    static func colorBurn(_ b: Float, _ s: Float) -> Float {
        if b >= 1 { return 1 }
        if s <= 0 { return 0 }
        return 1 - min(1, (1 - b) / s)
    }

    static func colorDodge(_ b: Float, _ s: Float) -> Float {
        if b <= 0 { return 0 }
        if s >= 1 { return 1 }
        return min(1, b / (1 - s))
    }

    static func hardLight(_ b: Float, _ s: Float) -> Float {
        s <= 0.5 ? 2 * b * s : 1 - 2 * (1 - b) * (1 - s)
    }

    static func softLight(_ b: Float, _ s: Float) -> Float {
        if s <= 0.5 { return b - (1 - 2 * s) * b * (1 - b) }
        let d = b <= 0.25 ? ((16 * b - 12) * b + 4) * b : b.squareRoot()
        return b + (2 * s - 1) * (d - b)
    }

    static func lum(_ c: SIMD3<Float>) -> Float { 0.3 * c.x + 0.59 * c.y + 0.11 * c.z }

    static func clipColor(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let l = lum(c)
        let n = c.min()
        let x = c.max()
        var out = c
        if n < 0 { out = SIMD3<Float>(repeating: l) + (out - l) * l / (l - n) }
        if x > 1 { out = SIMD3<Float>(repeating: l) + (out - l) * (1 - l) / (x - l) }
        return out
    }

    static func setLum(_ c: SIMD3<Float>, _ l: Float) -> SIMD3<Float> {
        clipColor(c + (l - lum(c)))
    }

    static func sat(_ c: SIMD3<Float>) -> Float { c.max() - c.min() }

    static func setSat(_ c: SIMD3<Float>, _ s: Float) -> SIMD3<Float> {
        let maxC = c.max()
        let minC = c.min()
        guard maxC > minC else { return .zero }
        return (c - minC) * s / (maxC - minC)
    }
}

/// Composition d'un calque sur ce qui est dessous (W3C : Cs' = (1 − αb)·s + αb·B(b, s), puis source-over).
public enum Compositing {
    /// `backdrop` et `source` en RGBA linéaire prémultiplié ; le résultat aussi.
    public static func composite(_ backdrop: SIMD4<Float>, _ source: SIMD4<Float>, mode: BlendMode,
                                 opacity: Float, space: BlendSpace) -> SIMD4<Float> {
        let sa = source.w * opacity
        guard sa > 0 else { return backdrop }
        let ba = backdrop.w
        let outA = sa + ba * (1 - sa)
        let sStraight = SIMD3<Float>(source.x, source.y, source.z) / source.w
        let bStraight = ba > 0 ? SIMD3<Float>(backdrop.x, backdrop.y, backdrop.z) / ba : SIMD3<Float>.zero
        let s = space == .perceptual ? ColorTransfer.toEncoded(sStraight) : sStraight
        let b = space == .perceptual ? ColorTransfer.toEncoded(bStraight) : bStraight
        let mixed = mode == .normal ? s : (1 - ba) * s + ba * mode.blend(b, s)
        let premultiplied = sa * mixed + (1 - sa) * ba * b
        let straight = premultiplied / outA
        let linear = space == .perceptual ? ColorTransfer.toLinear(straight) : straight
        let rgb = linear * outA
        return SIMD4<Float>(rgb.x, rgb.y, rgb.z, outA)
    }
}
