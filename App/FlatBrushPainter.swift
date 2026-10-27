import CoreGraphics
import Foundation
import PRCore
import simd

/// Peinture à plat (aperçus de trait, bloc à dessin de l'Atelier) avec le même calcul de dab que sur la sphère
/// (`BrushSettings.dab`) : taille, opacité, dispersion, rotation, miroir, rondeur, grain, variations, effilement,
/// vitesse et inclinaison. Le plan de l'image joue le rôle du plan tangent : `pixelsPerRadian` en donne l'échelle.
struct FlatBrushPainter {
    let width: Int
    let height: Int
    private(set) var alpha: [Float]
    var settings: BrushSettings
    let pixelsPerRadian: Double

    private var random = StrokeRandom(seed: 1)
    private var lastDab: SIMD2<Double>?
    private var previousDab: SIMD2<Double>?
    private var distance = 0.0
    private var speed = 0.0
    private var lastPoint: (position: SIMD2<Double>, time: Double)?
    private var grainOffset = SIMD2<Double>.zero
    private var rotationOffset = 0.0
    private static let origin: Vec3 = [0, 0, -1]

    init(width: Int, height: Int, settings: BrushSettings, pixelsPerRadian: Double) {
        self.width = width
        self.height = height
        self.settings = settings
        self.pixelsPerRadian = pixelsPerRadian
        alpha = [Float](repeating: 0, count: width * height)
    }

    mutating func clear() {
        alpha = [Float](repeating: 0, count: width * height)
    }

    /// Début d'un trait : tirages du trait (grain, angle de départ) et compteurs remis à zéro.
    mutating func begin(seed: UInt64) {
        random = StrokeRandom(seed: seed)
        grainOffset = [random.next(), random.next()]
        rotationOffset = random.next() * 2 * .pi
        lastDab = nil
        previousDab = nil
        distance = 0
        speed = 0
        lastPoint = nil
    }

    /// Ajoute un point du trait (pixels de l'image) : des dabs sont posés à l'espacement du pinceau depuis le précédent.
    mutating func addPoint(_ point: SIMD2<Double>, pressure: Double, tilt: Double = 0, time: Double) {
        if let last = lastPoint, time - last.time > 0.004 {
            let instant = simd_distance(point, last.position) / pixelsPerRadian / (time - last.time)
            speed = speed * 0.7 + instant * 0.3
        }
        lastPoint = (point, time)
        guard var from = lastDab else {
            lastDab = point
            stampAll(at: point, pressure: pressure, tilt: tilt)
            return
        }
        while true {
            let step = settings.spacing(radius: settings.radius(pressure: pressure), random: random.next()) * pixelsPerRadian
            let remaining = simd_distance(from, point)
            guard remaining >= max(0.5, step) else { break }
            from += (point - from) / remaining * max(0.5, step)
            stampAll(at: from, pressure: pressure, tilt: tilt)
        }
        lastDab = from
    }

    /// Les tampons d'un dab (Forme > Nombre), avec leurs tirages.
    private mutating func stampAll(at point: SIMD2<Double>, pressure: Double, tilt: Double) {
        if let previous = previousDab { distance += simd_distance(previous, point) / pixelsPerRadian }
        var angle = 0.0
        if let previous = previousDab, simd_distance(previous, point) > 1e-6 {
            angle = atan2(-(point.y - previous.y), point.x - previous.x)
        }
        previousDab = point
        let context = StrokeContext(distance: distance, speed: speed, tilt: tilt, grainOffset: grainOffset, rotationOffset: rotationOffset)
        let count = settings.stampCount(random: random.next())
        for _ in 0..<count {
            let r = settings.hasJitter ? random.dab() : .none
            let dab = settings.dab(at: Self.origin, pressure: pressure, color: .one, mode: .paint, strokeAngle: angle,
                                   random: r, context: context)
            // Dispersion : décalage du centre dans le plan tangent, ramené en pixels (y de l'image vers le bas).
            let offset = TangentFrame(center: Self.origin).project(dab.center) * pixelsPerRadian
            stamp(dab, at: point + SIMD2(offset.x, -offset.y))
        }
    }

    private mutating func stamp(_ dab: SphericalDab, at center: SIMD2<Double>) {
        let radiusPixels = max(0.75, dab.radius * pixelsPerRadian)
        let tip = dab.tip
        let reach = tip?.shape != nil ? radiusPixels * 1.42 : radiusPixels + 1
        let x0 = max(0, Int(center.x - reach)), x1 = min(width - 1, Int(center.x + reach))
        let y0 = max(0, Int(center.y - reach)), y1 = min(height - 1, Int(center.y + reach))
        guard x0 <= x1, y0 <= y1 else { return }
        let opacity = dab.color.w
        let pixelAngle = 1 / pixelsPerRadian
        for py in y0...y1 {
            for px in x0...x1 {
                // Point du plan tangent, en radians (nord vers le haut de l'image).
                let p = SIMD2<Double>((Double(px) + 0.5 - center.x) * pixelAngle, -(Double(py) + 0.5 - center.y) * pixelAngle)
                var a: Float
                if let tip, let value = tip.shapeValue(at: p, radius: dab.radius) {
                    a = value
                } else {
                    a = Float(SphericalRasterizer.coverage(distance: simd_length(p), radius: dab.radius,
                                                           hardness: dab.hardness, pixelSize: pixelAngle))
                }
                guard a > 0 else { continue }
                if let tip, let grain = tip.grain {
                    let g: Float
                    if tip.grainMoving {
                        g = tip.grainValue(at: Self.origin, local: p)
                    } else {
                        // Texturé : fixé à l'image, comme il l'est à la sphère.
                        let s = 1 / (tip.grainScale * pixelsPerRadian)
                        g = grain.sample(Double(px) * s, Double(py) * s, wrap: true)
                    }
                    a *= 1 - Float(tip.grainDepth) * (1 - g)
                }
                let i = py * width + px
                alpha[i] += a * opacity * (1 - alpha[i])
            }
        }
    }

    /// Blanc sur transparent.
    func image() -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let a = UInt8(min(1, alpha[i]) * 255 + 0.5)
            bytes[i * 4] = a
            bytes[i * 4 + 1] = a
            bytes[i * 4 + 2] = a
            bytes[i * 4 + 3] = a
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Aperçu standard : une ondulation de gauche à droite, pression qui monte puis redescend (un seul tampon si c'est un tampon).
    static func preview(_ settings: BrushSettings, width: Int, height: Int, radiusPixels: Double) -> CGImage? {
        var painter = FlatBrushPainter(width: width, height: height, settings: settings,
                                       pixelsPerRadian: radiusPixels / max(1e-6, settings.radiusDegrees * .pi / 180))
        painter.begin(seed: 7)
        if settings.spacing >= 10 {
            painter.addPoint([Double(width) / 2, Double(height) / 2], pressure: 1, time: 0)
            return painter.image()
        }
        let margin = radiusPixels + 2
        let steps = 120
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let x = margin + t * (Double(width) - 2 * margin)
            let y = Double(height) / 2 + sin(t * 2 * .pi) * Double(height) * 0.18
            painter.addPoint([x, y], pressure: 0.35 + 0.65 * sin(t * .pi), time: t * 0.6)
        }
        return painter.image()
    }
}
