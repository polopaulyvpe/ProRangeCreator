import simd

/// Courbe de tons monotone (interpolation cubique de Fritsch–Carlson) sur les valeurs encodées.
/// Le domaine peut dépasser 1 (`maxInput`, jusqu'à 16) pour retoucher les hautes lumières HDR.
public struct ToneCurve: Equatable, Sendable {
    /// Points de contrôle triés par x, x et y dans [0, maxInput].
    public var points: [SIMD2<Double>]
    public var maxInput: Double

    public init(points: [SIMD2<Double>] = [[0, 0], [1, 1]], maxInput: Double = 1) {
        self.maxInput = max(1, maxInput)
        self.points = points.sorted { $0.x < $1.x }
    }

    public static let identity = ToneCurve()

    public func evaluate(_ x: Double) -> Double {
        let pts = points
        guard pts.count >= 2 else { return x }
        if x <= pts[0].x { return pts[0].y + (x - pts[0].x) * slopes()[0] }
        if x >= pts[pts.count - 1].x {
            // Au-delà du dernier point : prolongement linéaire (les valeurs HDR restent ordonnées).
            return pts[pts.count - 1].y + (x - pts[pts.count - 1].x) * slopes()[pts.count - 1]
        }
        let i = pts.indices.dropLast().last { pts[$0].x <= x }!
        let m = slopes()
        let h = pts[i + 1].x - pts[i].x
        let t = (x - pts[i].x) / h
        let t2 = t * t, t3 = t2 * t
        let h00: Double = 2 * t3 - 3 * t2 + 1
        let h10: Double = t3 - 2 * t2 + t
        let h01: Double = -2 * t3 + 3 * t2
        let h11: Double = t3 - t2
        let a: Double = h00 * pts[i].y + h10 * h * m[i]
        let b: Double = h01 * pts[i + 1].y + h11 * h * m[i + 1]
        return a + b
    }

    /// Pentes de Fritsch–Carlson (garantissent une courbe monotone si les points le sont).
    private func slopes() -> [Double] {
        let p = points
        let n = p.count
        var delta = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { delta[i] = (p[i + 1].y - p[i].y) / max(p[i + 1].x - p[i].x, 1e-9) }
        var m = [Double](repeating: 0, count: n)
        m[0] = delta[0]
        m[n - 1] = delta[n - 2]
        for i in 1..<(n - 1) { m[i] = delta[i - 1] * delta[i] <= 0 ? 0 : (delta[i - 1] + delta[i]) / 2 }
        for i in 0..<(n - 1) where delta[i] == 0 {
            m[i] = 0
            m[i + 1] = 0
        }
        for i in 0..<(n - 1) where delta[i] != 0 {
            let a = m[i] / delta[i], b = m[i + 1] / delta[i]
            let s = a * a + b * b
            if s > 9 {
                let tau = 3 / s.squareRoot()
                m[i] = tau * a * delta[i]
                m[i + 1] = tau * b * delta[i]
            }
        }
        return m
    }

    /// Table d'échantillons régulière sur [0, maxInput] (pour le GPU).
    public func table(count: Int = 1024) -> [Float] {
        (0..<count).map { Float(evaluate(Double($0) / Double(count - 1) * maxInput)) }
    }
}

/// Ajustements point par point, calculés sur la couleur droite encodée (comme Procreate), courbe prolongée au-delà de 1.
public enum Adjustment: Equatable, Sendable {
    /// Teinte (tours, −0,5…0,5), saturation et luminosité (−1…1).
    case hueSaturation(hue: Double, saturation: Double, brightness: Double)
    /// Décalages de couleur pour les ombres, tons moyens et hautes lumières (−1…1 par canal).
    case colorBalance(shadows: SIMD3<Double>, midtones: SIMD3<Double>, highlights: SIMD3<Double>)
    /// Courbe appliquée à chaque canal (sur la valeur encodée).
    case curves(ToneCurve)
    /// La luminance choisit une couleur entre `dark` et `light` (couleurs encodées).
    case gradientMap(dark: SIMD3<Double>, light: SIMD3<Double>)
    /// Remplace une teinte par une autre, dans une plage de tolérance (tours).
    case recolor(from: Double, to: Double, tolerance: Double)

    public var label: String {
        switch self {
        case .hueSaturation: "Teinte, saturation, luminosité"
        case .colorBalance: "Balance des couleurs"
        case .curves: "Courbes"
        case .gradientMap: "Carte de dégradé"
        case .recolor: "Recoloration"
        }
    }

    /// Applique l'ajustement à un pixel RGBA linéaire prémultiplié.
    public func apply(_ p: SIMD4<Float>) -> SIMD4<Float> {
        guard p.w > 0 else { return p }
        let straight = SIMD3<Float>(p.x, p.y, p.z) / p.w
        let encoded = ColorTransfer.toEncoded(straight)
        let adjusted = simd_max(applyEncoded(SIMD3<Double>(encoded)), .zero)
        let linear = ColorTransfer.toLinear(SIMD3<Float>(adjusted)) * p.w
        return SIMD4<Float>(linear.x, linear.y, linear.z, p.w)
    }

    /// Sur une couleur droite encodée (peut dépasser 1).
    public func applyEncoded(_ c: SIMD3<Double>) -> SIMD3<Double> {
        switch self {
        case let .hueSaturation(hue, saturation, brightness):
            // Garde l'excès HDR à part : HSB n'a de sens que sur [0, 1].
            let peak = max(1, c.max())
            var hsb = HSBColor(rgb: c / peak)
            hsb.hue = (hsb.hue + hue).truncatingRemainder(dividingBy: 1)
            if hsb.hue < 0 { hsb.hue += 1 }
            hsb.saturation = min(1, max(0, hsb.saturation * (1 + saturation)))
            hsb.brightness = max(0, hsb.brightness * (1 + brightness))
            return hsb.rgb * peak
        case let .colorBalance(shadows, midtones, highlights):
            let l = min(1, max(0, 0.3 * c.x + 0.59 * c.y + 0.11 * c.z))
            let shadowWeight = max(0, 1 - l * 2)
            let highlightWeight = max(0, l * 2 - 1)
            let midWeight = 1 - shadowWeight - highlightWeight
            return c + (shadows * shadowWeight + midtones * midWeight + highlights * highlightWeight) * 0.25
        case let .curves(curve):
            return [curve.evaluate(c.x), curve.evaluate(c.y), curve.evaluate(c.z)]
        case let .gradientMap(dark, light):
            let l = 0.3 * c.x + 0.59 * c.y + 0.11 * c.z
            return dark + (light - dark) * l
        case let .recolor(from, to, tolerance):
            let peak = max(1, c.max())
            var hsb = HSBColor(rgb: c / peak)
            var distance = abs(hsb.hue - from)
            distance = min(distance, 1 - distance)
            guard hsb.saturation > 0.05, distance < tolerance else { return c }
            let weight = 1 - distance / tolerance
            var shift = to - from
            shift -= shift.rounded()
            hsb.hue = (hsb.hue + shift * weight + 1).truncatingRemainder(dividingBy: 1)
            return hsb.rgb * peak
        }
    }
}

/// Bruit défini sur la sphère : valeur pseudo-aléatoire d'une cellule d'un réseau 3D de pas `cell` (radians).
/// Les cellules coupent la sphère en taches de taille à peu près constante partout (pôles et couture compris),
/// contrairement à un bruit par texel équirectangulaire qui serait plus fin aux pôles.
public enum SphericalNoise {
    public static func value(_ d: Vec3, cell: Double, seed: UInt32, channel: UInt32 = 0) -> Float {
        let q = SIMD3<Int32>(Int32(clamping: Int((d.x / cell).rounded(.down))),
                             Int32(clamping: Int((d.y / cell).rounded(.down))),
                             Int32(clamping: Int((d.z / cell).rounded(.down))))
        return hash(q, seed: seed &+ channel &* 0x9E37_79B9)
    }

    /// Hachage entier (le même en MSL) vers [0, 1).
    public static func hash(_ q: SIMD3<Int32>, seed: UInt32) -> Float {
        var h = UInt32(bitPattern: q.x) &* 0x8DA6_B343
        h ^= UInt32(bitPattern: q.y) &* 0xD816_3841
        h ^= UInt32(bitPattern: q.z) &* 0xCB1A_B31F
        h ^= seed
        h ^= h >> 16
        h = h &* 0x7FEB_352D
        h ^= h >> 15
        h = h &* 0x846C_A68B
        h ^= h >> 16
        return Float(h >> 8) / Float(1 << 24)
    }
}

/// Filtres à voisinage, tous définis en angles sur la sphère.
public enum SphereFilter: Equatable, Sendable {
    /// Flou gaussien d'écart-type angulaire `radius`.
    case gaussianBlur(radius: Double)
    /// Flou de mouvement : moyenne le long du grand cercle tangent à la direction `angle` (depuis l'est local), sur `length`.
    case motionBlur(length: Double, angle: Double)
    /// Grain : ± `amount` sur la valeur encodée, cellules de taille `cell`.
    case noise(amount: Double, cell: Double, seed: UInt32, monochrome: Bool)
    /// Netteté par masque flou : original + amount × (original − flou).
    case sharpen(radius: Double, amount: Double)
    /// Halo des hautes lumières : flou de ce qui dépasse `threshold` (linéaire), ajouté × intensity.
    case bloom(threshold: Double, radius: Double, intensity: Double)
    /// Aberration chromatique autour de `center` : rouge et bleu écartés de ± `strength` (fraction de l'angle au centre).
    case chromaticAberration(center: Vec3, strength: Double)

    public var label: String {
        switch self {
        case .gaussianBlur: "Flou gaussien"
        case .motionBlur: "Flou de mouvement"
        case .noise: "Bruit"
        case .sharpen: "Netteté"
        case .bloom: "Bloom"
        case .chromaticAberration: "Aberration chromatique"
        }
    }
}
