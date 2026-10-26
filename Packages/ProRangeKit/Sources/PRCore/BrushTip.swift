import Foundation
import simd

/// Image en niveaux de gris (carrée, valeurs dans [0, 1], blanc = peinture) : forme ou grain d'un pinceau.
/// Immuable, partagée par référence entre les réglages, les dabs et le cache de textures GPU.
public final class BrushTexture: Sendable, Hashable {
    public let name: String
    public let size: Int
    /// Lignes de haut en bas.
    public let values: [Float]

    public init(name: String, size: Int, values: [Float]) {
        precondition(size > 0 && values.count == size * size)
        self.name = name
        self.size = size
        self.values = values
    }

    public static func == (a: BrushTexture, b: BrushTexture) -> Bool { a === b }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    /// Bilinéaire, coordonnées normalisées (centre du texel i en (i + 0,5) / taille) ; répétée si `wrap`, bornée sinon.
    /// Même convention que l'échantillonneur Metal.
    public func sample(_ u: Double, _ v: Double, wrap: Bool) -> Float {
        let x = u * Double(size) - 0.5
        let y = v * Double(size) - 0.5
        let x0f = floor(x)
        let y0f = floor(y)
        let fx = Float(x - x0f)
        let fy = Float(y - y0f)
        func index(_ i: Int) -> Int {
            wrap ? ((i % size) + size) % size : min(size - 1, max(0, i))
        }
        let x0 = index(Int(x0f)), x1 = index(Int(x0f) + 1)
        let y0 = index(Int(y0f)), y1 = index(Int(y0f) + 1)
        let top = values[y0 * size + x0] * (1 - fx) + values[y0 * size + x1] * fx
        let bottom = values[y1 * size + x0] * (1 - fx) + values[y1 * size + x1] * fx
        return top * (1 - fy) + bottom * fy
    }

    /// Ramène une image en niveaux de gris quelconque à un carré de côté ≤ `maxSize` (recadrage central, moyenne de blocs),
    /// avec inversion éventuelle (formes noires sur fond blanc).
    public static func make(name: String, gray: [Float], width: Int, height: Int, maxSize: Int = 512, invert: Bool = false) -> BrushTexture {
        let side = min(width, height)
        let x0 = (width - side) / 2
        let y0 = (height - side) / 2
        let size = min(maxSize, side)
        var values = [Float](repeating: 0, count: size * size)
        let scale = Double(side) / Double(size)
        for y in 0..<size {
            let sy0 = Int(Double(y) * scale), sy1 = max(sy0 + 1, Int(Double(y + 1) * scale))
            for x in 0..<size {
                let sx0 = Int(Double(x) * scale), sx1 = max(sx0 + 1, Int(Double(x + 1) * scale))
                var sum: Float = 0
                for sy in sy0..<sy1 {
                    for sx in sx0..<sx1 { sum += gray[(y0 + sy) * width + x0 + sx] }
                }
                let v = min(1, max(0, sum / Float((sy1 - sy0) * (sx1 - sx0))))
                values[y * size + x] = invert ? 1 - v : v
            }
        }
        return BrushTexture(name: name, size: size, values: values)
    }
}

/// Forme et grain d'un dab, avec leur placement.
public struct DabTip: Sendable, Equatable {
    /// Forme étendue sur le carré [-rayon, rayon]² du plan tangent ; nil = rond (dureté).
    public var shape: BrushTexture?
    /// Grain fixé à la sphère (projection triplanaire de la direction) ; nil = pas de grain.
    public var grain: BrushTexture?
    /// Angle de la forme par rapport à l'est local, en radians (sens direct).
    public var rotation: Double
    /// Taille angulaire d'un motif de grain, en radians.
    public var grainScale: Double
    /// Profondeur du grain dans [0, 1] : 0 = sans effet, 1 = la peinture ne passe que sur le blanc du grain.
    public var grainDepth: Double

    public init(shape: BrushTexture? = nil, grain: BrushTexture? = nil, rotation: Double = 0,
                grainScale: Double = 0.05, grainDepth: Double = 1) {
        self.shape = shape
        self.grain = grain
        self.rotation = rotation
        self.grainScale = grainScale
        self.grainDepth = grainDepth
    }

    /// Valeur du grain dans une direction : mélange des trois projections planes, poids |d|⁴ (sans couture).
    public func grainValue(at d: Vec3) -> Float {
        guard let grain else { return 1 }
        let s = 1 / grainScale
        var w = simd_abs(d)
        w = w * w
        w = w * w
        w /= w.x + w.y + w.z
        let gx = grain.sample(d.y * s, d.z * s, wrap: true)
        let gy = grain.sample(d.x * s, d.z * s, wrap: true)
        let gz = grain.sample(d.x * s, d.y * s, wrap: true)
        return Float(w.x) * gx + Float(w.y) * gy + Float(w.z) * gz
    }

    /// Couverture de la forme au point `p` du plan tangent (radians), pour un rayon donné ; nil si hors du carré.
    public func shapeValue(at p: SIMD2<Double>, radius: Double) -> Float? {
        guard let shape else { return nil }
        let c = cos(rotation), s = sin(rotation)
        let x = (p.x * c + p.y * s) / radius
        let y = (-p.x * s + p.y * c) / radius
        guard abs(x) <= 1, abs(y) <= 1 else { return 0 }
        return shape.sample((x + 1) / 2, (1 - y) / 2, wrap: false)
    }
}
