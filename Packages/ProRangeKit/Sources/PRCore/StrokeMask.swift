import simd

/// Rendu d'un trait (Atelier > Rendu). Le trait est d'abord accumulé dans un masque (voir `StrokeMask`),
/// puis posé sur le calque en une fois : un glacis ne s'assombrit pas là où le trait repasse sur lui-même.
/// Les noms reprennent ceux de Procreate ; leur comportement est le nôtre (son moteur n'est pas documenté) :
/// - glacis léger : le trait plafonne à l'opacité de chaque tampon, le flux le fait monter vers ce plafond ;
/// - glacis uniforme : idem, flux sans effet de la pression ;
/// - glacis intense : les tampons s'accumulent sans plafond (le comportement d'avant le masque) ;
/// - glacis épais : accumulation, flux renforcé (racine carrée) ;
/// - mélanges uniforme et intense : comme les glacis du même nom tant que le mélange humide n'existe pas.
public enum BrushRendering: String, CaseIterable, Codable, Sendable {
    case lightGlaze, uniformGlaze, intenseGlaze, heavyGlaze, uniformBlending, intenseBlending

    public var label: String {
        switch self {
        case .lightGlaze: "Glacis léger"
        case .uniformGlaze: "Glacis uniforme"
        case .intenseGlaze: "Glacis intense"
        case .heavyGlaze: "Glacis épais"
        case .uniformBlending: "Mélange uniforme"
        case .intenseBlending: "Mélange intense"
        }
    }

    /// Le trait plafonne à l'opacité des tampons.
    public var capsOpacity: Bool {
        switch self {
        case .lightGlaze, .uniformGlaze, .uniformBlending: true
        case .intenseGlaze, .heavyGlaze, .intenseBlending: false
        }
    }

    /// La pression ne change pas le flux.
    public var uniformFlow: Bool { self == .uniformGlaze || self == .uniformBlending }

    /// Flux effectif pour un flux réglé `flow`.
    public func flow(_ flow: Double) -> Double {
        self == .heavyGlaze ? flow.squareRoot() : flow
    }
}

/// Combinaison du pinceau principal et du pinceau secondaire d'un pinceau double (codes Procreate entre parenthèses).
/// P = couverture du principal, S = celle du secondaire, toutes deux dans [0, 1].
public enum DualBlendMode: String, CaseIterable, Codable, Sendable {
    case multiply, darken, overlay, colorDodge, colorBurn, linearBurn, hardMix, subtract

    public var label: String {
        switch self {
        case .multiply: "Produit"
        case .darken: "Obscurcir"
        case .overlay: "Incrustation"
        case .colorDodge: "Densité couleur −"
        case .colorBurn: "Densité couleur +"
        case .linearBurn: "Densité linéaire +"
        case .hardMix: "Mélange maximal"
        case .subtract: "Soustraction"
        }
    }

    /// Code de mode de fusion Procreate (`dualBlendMode`) ; inconnu → produit.
    public init(procreateCode code: Int) {
        switch code {
        case 7: self = .subtract
        case 8: self = .linearBurn
        case 9: self = .colorDodge
        case 10: self = .colorBurn
        case 11: self = .overlay
        case 19: self = .darken
        case 20: self = .hardMix
        default: self = .multiply
        }
    }

    @inline(__always)
    public func combine(_ p: Float, _ s: Float) -> Float {
        let r: Float
        switch self {
        case .multiply: r = p * s
        case .darken: r = min(p, s)
        case .overlay: r = p < 0.5 ? 2 * p * s : 1 - 2 * (1 - p) * (1 - s)
        case .colorDodge: r = s >= 1 ? (p > 0 ? 1 : 0) : p / (1 - s)
        case .colorBurn: r = s <= 0 ? 0 : 1 - (1 - p) / s
        case .linearBurn: r = p + s - 1
        // Seuil : plein là où les deux couvertures dépassent 1 ensemble, rien ailleurs (bord adouci sur 0,1).
        case .hardMix: r = (p + s - 1) / 0.1
        case .subtract: r = p - s
        }
        return min(1, max(0, r))
    }

    /// Index pour le kernel Metal (même ordre que `allCases`).
    public var index: Int { Self.allCases.firstIndex(of: self)! }
}

/// Façon de poser un trait sur le calque : couleur, peindre ou effacer, rendu des deux pinceaux, combinaison.
public struct StrokeStyle: Sendable, Equatable {
    /// RGB linéaire non prémultiplié.
    public var color: SIMD3<Float>
    public var mode: DabMode
    public var capsPrimary: Bool
    public var capsSecondary: Bool
    /// Combinaison avec le pinceau secondaire ; nil = pinceau simple.
    public var dual: DualBlendMode?
    /// Chaque tampon apporte sa couleur (dynamique de couleur, mélange humide) : le trait garde une couleur par texel
    /// (voir `StrokeMask.depositColor`) au lieu de `color`.
    public var varyingColor: Bool

    public init(color: SIMD3<Float>, mode: DabMode = .paint, capsPrimary: Bool = true, capsSecondary: Bool = true,
                dual: DualBlendMode? = nil, varyingColor: Bool = false) {
        self.color = color
        self.mode = mode
        self.capsPrimary = capsPrimary
        self.capsSecondary = capsSecondary
        self.dual = dual
        self.varyingColor = varyingColor
    }
}

/// Masque d'un trait, par texel : x = couverture accumulée du principal (avec le flux), y = son plafond (opacité maximale
/// des tampons), z et w = la même chose pour le secondaire. Référence CPU du kernel `stampMask` / `applyStroke`.
public enum StrokeMask {
    /// Ajoute un tampon de couverture `coverage` (forme × grain), d'opacité `opacity` et de flux `flow`.
    @inline(__always)
    public static func accumulate(_ m: inout SIMD4<Float>, coverage: Float, opacity: Float, flow: Float, secondary: Bool) {
        let a = coverage * opacity
        let f = a * flow
        if secondary {
            m.z += f * (1 - m.z)
            m.w = max(m.w, a)
        } else {
            m.x += f * (1 - m.x)
            m.y = max(m.y, a)
        }
    }

    /// Couleur du trait en ce texel quand chaque tampon a la sienne (`StrokeStyle.varyingColor`), à appeler avant
    /// `accumulate` avec le masque d'avant le tampon (principal seulement). Le tampon remplace la couleur en proportion de
    /// ce qu'il ajoute au masque, et au moins de sa propre opacité × flux : sur un texel vierge il la pose telle quelle,
    /// sur un glacis déjà plein il la recouvre selon sa force (une variation de couleur reste visible).
    @inline(__always)
    public static func depositColor(_ c: inout SIMD3<Float>, mask m: SIMD4<Float>, coverage: Float, opacity: Float, flow: Float,
                                    color: SIMD3<Float>) {
        let f = coverage * opacity * flow
        guard f > 0 else { return }
        let added = f * (1 - m.x)
        let w = min(1, max(added / max(m.x + added, 1e-6), f))
        c = w >= 1 ? color : c + (color - c) * w
    }

    /// Opacité finale du trait en ce texel.
    @inline(__always)
    public static func alpha(_ m: SIMD4<Float>, style: StrokeStyle) -> Float {
        let p = style.capsPrimary ? min(m.x, m.y) : m.x
        guard let dual = style.dual else { return p }
        let s = style.capsSecondary ? min(m.z, m.w) : m.z
        return dual.combine(p, s)
    }

    /// Pixel du calque (RGBA linéaire prémultiplié) : l'original d'avant le trait, avec le trait posé d'opacité `alpha`,
    /// de la couleur du style ou de `color` (couleur du texel, pinceau à couleur variable).
    @inline(__always)
    public static func composite(_ original: SIMD4<Float>, alpha: Float, style: StrokeStyle, space: BlendSpace,
                                 alphaLock: Bool, color texel: SIMD3<Float>? = nil) -> SIMD4<Float> {
        guard alpha > 0 else { return original }
        var dst = original
        switch style.mode {
        case .erase:
            dst *= 1 - alpha
        case .paint:
            let rgb = texel ?? style.color
            let color = SIMD4<Float>(rgb.x, rgb.y, rgb.z, 1)
            switch space {
            case .linear: SphericalRasterizer.blend(color, coverage: alpha, into: &dst)
            case .perceptual: SphericalRasterizer.blendPerceptual(color, coverage: alpha, into: &dst)
            }
        }
        guard alphaLock else { return dst }
        if original.w > 0, dst.w > 0 {
            let rgb = SIMD3<Float>(dst.x, dst.y, dst.z) / dst.w * original.w
            return SIMD4<Float>(rgb.x, rgb.y, rgb.z, original.w)
        }
        return original
    }
}
