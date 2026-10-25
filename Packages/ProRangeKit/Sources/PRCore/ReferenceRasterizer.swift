import simd

/// Toile équirectangulaire CPU en RGBA flottant linéaire prémultiplié.
/// Sert de référence pour valider les kernels Metal, et de toile au spike. Pas faite pour le 16K.
public final class EquirectCanvas {
    public let width: Int
    public let height: Int
    public var pixels: [SIMD4<Float>]
    public let geometry: EquirectGeometry

    public init(width: Int, height: Int, fill: SIMD4<Float> = .zero) {
        self.width = width
        self.height = height
        geometry = EquirectGeometry(width: width, height: height)
        pixels = Array(repeating: fill, count: width * height)
    }

    public subscript(x: Int, y: Int) -> SIMD4<Float> {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Identique à `Equirect.direction(x:y:width:height:)`, avec sinus/cosinus précalculés.
    public func direction(x: Int, y: Int) -> Vec3 { geometry.direction(x: x, y: y) }

    /// Angle solide (stéradians) d'un texel de la rangée `y`.
    public func texelSolidAngle(row y: Int) -> Double { geometry.texelSolidAngle(row: y) }

    /// Pas angulaire d'une rangée de texels.
    public var pixelAngle: Double { geometry.pixelAngle }

    public func clear(to value: SIMD4<Float>) {
        for i in pixels.indices { pixels[i] = value }
    }

    /// Encode des rangées en RGBA8 sRGB (prémultiplié) dans `buffer` (width × height × 4 octets).
    public func encodeSRGB8(rows: ClosedRange<Int>, into buffer: inout [UInt8]) {
        for y in rows {
            for x in 0..<width {
                let p = pixels[y * width + x]
                let o = (y * width + x) * 4
                buffer[o] = ColorTransfer.encode8(p.x)
                buffer[o + 1] = ColorTransfer.encode8(p.y)
                buffer[o + 2] = ColorTransfer.encode8(p.z)
                buffer[o + 3] = UInt8(min(1, max(0, p.w)) * 255 + 0.5)
            }
        }
    }
}

/// Un tampon de pinceau rond, défini sur la sphère.
public struct SphericalDab: Sendable {
    public var center: Vec3
    /// Rayon angulaire en radians.
    public var radius: Double
    /// 1 = bord net, 0 = dégradé depuis le centre.
    public var hardness: Double
    /// RGB linéaire non prémultiplié ; `w` = opacité.
    public var color: SIMD4<Float>
    public var mode: DabMode

    public init(center: Vec3, radius: Double, hardness: Double, color: SIMD4<Float>, mode: DabMode = .paint) {
        self.center = center
        self.radius = radius
        self.hardness = hardness
        self.color = color
        self.mode = mode
    }
}

/// Peindre ou effacer : même moteur, même forme (la gomme n'utilise que l'opacité de `color`).
public enum DabMode: Sendable {
    case paint
    case erase
}

public enum SphericalRasterizer {
    /// Couverture d'un point à la distance `distance` du centre, pour un rayon `radius`.
    /// Bord antialiasé linéairement sur ±½ `pixelSize` autour du rayon.
    public static func coverage(distance: Double, radius: Double, hardness: Double, pixelSize: Double) -> Double {
        let rho = distance / radius
        let e = pixelSize / radius
        let edge = min(1, max(0, (1 - rho) / e + 0.5))
        if hardness >= 1 || rho <= hardness { return edge }
        let t = min(1, (rho - hardness) / (1 - hardness))
        return edge * (1 - t * t * (3 - 2 * t))
    }

    /// Rend un dab texel par texel : chaque texel est projeté dans le plan tangent au point d'impact.
    /// `bruteForce` parcourt toute la toile (pour tester `EquirectSpan`). Renvoie les rangées modifiées.
    @discardableResult
    public static func stamp(_ dab: SphericalDab, on canvas: EquirectCanvas, space: BlendSpace = .perceptual,
                             bruteForce: Bool = false) -> ClosedRange<Int>? {
        let evaluator = DabEvaluator(dab, pixelAngle: canvas.pixelAngle)
        let span = bruteForce
            ? EquirectSpan(rows: 0...(canvas.height - 1), columns: [0...(canvas.width - 1)])
            : evaluator.span(in: canvas.geometry)

        var touched: ClosedRange<Int>?
        for y in span.rows {
            for range in span.columns {
                for x in range {
                    let a = evaluator.coverage(at: canvas.direction(x: x, y: y))
                    if a <= 0 { continue }
                    apply(dab, coverage: a, to: &canvas.pixels[y * canvas.width + x], space: space)
                    touched = touched.map { min($0.lowerBound, y)...max($0.upperBound, y) } ?? y...y
                }
            }
        }
        return touched
    }

    /// Tampon rond en espace pixel (pour comparer avec l'empreinte sphérique). Boucle en x, borné en y.
    @discardableResult
    public static func stampScreenSpace(center: SIMD2<Double>, radiusPixels: Double, hardness: Double,
                                        color: SIMD4<Float>, on canvas: EquirectCanvas) -> ClosedRange<Int>? {
        let reach = radiusPixels + 1
        let y0 = max(0, Int(floor(center.y - reach)))
        let y1 = min(canvas.height - 1, Int(ceil(center.y + reach)))
        guard y0 <= y1 else { return nil }
        let x0 = Int(floor(center.x - reach))
        let x1 = Int(ceil(center.x + reach))
        for y in y0...y1 {
            for xi in x0...x1 {
                let dx = Double(xi) + 0.5 - center.x
                let dy = Double(y) + 0.5 - center.y
                let a = coverage(distance: (dx * dx + dy * dy).squareRoot(), radius: radiusPixels,
                                 hardness: hardness, pixelSize: 1)
                if a <= 0 { continue }
                let x = ((xi % canvas.width) + canvas.width) % canvas.width
                blend(color, coverage: Float(a), into: &canvas.pixels[y * canvas.width + x])
            }
        }
        return y0...y1
    }

    /// Applique un dab à un pixel (RGBA linéaire prémultiplié).
    @inline(__always)
    public static func apply(_ dab: SphericalDab, coverage: Float, to dst: inout SIMD4<Float>, space: BlendSpace) {
        switch dab.mode {
        case .erase:
            dst *= 1 - coverage * dab.color.w
        case .paint:
            switch space {
            case .linear: blend(dab.color, coverage: coverage, into: &dst)
            case .perceptual: blendPerceptual(dab.color, coverage: coverage, into: &dst)
            }
        }
    }

    /// Source-over sur les valeurs encodées (comme Procreate), stockage linéaire prémultiplié.
    @inline(__always)
    public static func blendPerceptual(_ color: SIMD4<Float>, coverage: Float, into dst: inout SIMD4<Float>) {
        let sa = coverage * color.w
        let da = dst.w
        let outA = sa + da * (1 - sa)
        guard outA > 0 else {
            dst = .zero
            return
        }
        let src = ColorTransfer.toEncoded(SIMD3<Float>(color.x, color.y, color.z))
        let below = da > 0 ? ColorTransfer.toEncoded(SIMD3<Float>(dst.x, dst.y, dst.z) / da) : SIMD3<Float>.zero
        let mixed = (src * sa + below * (da * (1 - sa))) / outA
        let rgb = ColorTransfer.toLinear(mixed) * outA
        dst = SIMD4<Float>(rgb.x, rgb.y, rgb.z, outA)
    }

    /// Source-over prémultiplié en lumière linéaire.
    @inline(__always)
    public static func blend(_ color: SIMD4<Float>, coverage: Float, into dst: inout SIMD4<Float>) {
        let a = coverage * color.w
        let src = SIMD4<Float>(color.x * a, color.y * a, color.z * a, a)
        dst = src + dst * (1 - a)
    }
}
