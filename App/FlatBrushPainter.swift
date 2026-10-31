import CoreGraphics
import Foundation
import PRCore
import simd

/// Peinture à plat (aperçus de trait, bloc à dessin de l'Atelier) avec le même calcul de dab que sur la sphère
/// (`BrushSettings.dab`) : taille, opacité, dispersion, rotation, miroir, rondeur, grain, variations, effilement,
/// vitesse et inclinaison. Le plan de l'image joue le rôle du plan tangent : `pixelsPerRadian` en donne l'échelle.
/// Comme sur la toile, chaque trait s'accumule dans un masque (`StrokeMask` : glacis, flux, pinceau double)
/// puis se pose sur les traits précédents.
struct FlatBrushPainter {
    let width: Int
    let height: Int
    /// Traits terminés.
    private var committed: [Float]
    /// Masque du trait en cours.
    private var mask: [SIMD4<Float>]
    var settings: BrushSettings
    let pixelsPerRadian: Double

    /// Pose des dabs d'un pinceau (principal ou secondaire) le long du trait.
    private struct Stream {
        var random = StrokeRandom(seed: 1)
        var lastDab: SIMD2<Double>?
        var previousDab: SIMD2<Double>?
        var distance = 0.0
    }

    private var primary = Stream()
    private var secondary = Stream()
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
        committed = [Float](repeating: 0, count: width * height)
        mask = [SIMD4<Float>](repeating: .zero, count: width * height)
    }

    mutating func clear() {
        committed = [Float](repeating: 0, count: width * height)
        mask = [SIMD4<Float>](repeating: .zero, count: width * height)
    }

    private var style: StrokeStyle { settings.strokeStyle(color: .one, mode: .paint) }

    /// Début d'un trait : le précédent est posé, tirages du trait (grain, angle de départ) et compteurs remis à zéro.
    mutating func begin(seed: UInt64) {
        let style = style
        for i in mask.indices where mask[i] != .zero {
            let a = StrokeMask.alpha(mask[i], style: style)
            committed[i] = a + committed[i] * (1 - a)
            mask[i] = .zero
        }
        primary = Stream(random: StrokeRandom(seed: seed))
        secondary = Stream(random: StrokeRandom(seed: seed &+ 0x5EC0))
        grainOffset = [primary.random.next(), primary.random.next()]
        rotationOffset = primary.random.next() * 2 * .pi
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
        // Copie locale du flux : on ne peut pas passer une propriété en inout à une méthode mutante de la même structure.
        var stream = primary
        advance(&stream, brush: settings, isSecondary: false, to: point, pressure: pressure, tilt: tilt)
        primary = stream
        if let second = settings.resolvedSecondary {
            stream = secondary
            advance(&stream, brush: second, isSecondary: true, to: point, pressure: pressure, tilt: tilt)
            secondary = stream
        }
    }

    private mutating func advance(_ stream: inout Stream, brush: BrushSettings, isSecondary: Bool, to point: SIMD2<Double>,
                                  pressure: Double, tilt: Double) {
        guard var from = stream.lastDab else {
            stream.lastDab = point
            stampAll(&stream, brush: brush, isSecondary: isSecondary, at: point, pressure: pressure, tilt: tilt)
            return
        }
        while true {
            let step = brush.spacing(radius: brush.radius(pressure: pressure), random: stream.random.next(), speed: speed) * pixelsPerRadian
            let remaining = simd_distance(from, point)
            guard remaining >= max(0.5, step) else { break }
            from += (point - from) / remaining * max(0.5, step)
            stampAll(&stream, brush: brush, isSecondary: isSecondary, at: from, pressure: pressure, tilt: tilt)
        }
        stream.lastDab = from
    }

    /// Les tampons d'un dab (Forme > Nombre), avec leurs tirages.
    private mutating func stampAll(_ stream: inout Stream, brush: BrushSettings, isSecondary: Bool, at point: SIMD2<Double>,
                                   pressure: Double, tilt: Double) {
        if let previous = stream.previousDab { stream.distance += simd_distance(previous, point) / pixelsPerRadian }
        var angle = 0.0
        if let previous = stream.previousDab, simd_distance(previous, point) > 1e-6 {
            angle = atan2(-(point.y - previous.y), point.x - previous.x)
        }
        stream.previousDab = point
        let context = StrokeContext(distance: stream.distance, speed: speed, tilt: tilt, grainOffset: grainOffset,
                                    rotationOffset: rotationOffset)
        let count = brush.stampCount(random: stream.random.next())
        for _ in 0..<count {
            let r = brush.hasJitter ? stream.random.dab() : .none
            var dab = brush.dab(at: Self.origin, pressure: pressure, color: .one, mode: .paint, strokeAngle: angle,
                                random: r, context: context)
            dab.secondary = isSecondary
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
        let pixelAngle = 1 / pixelsPerRadian
        // Filtrage amélioré : même niveau de réduction des textures que sur la toile, à cette échelle.
        let shapeLOD = tip?.shapeLOD(radius: dab.radius, pixelAngle: pixelAngle) ?? 0
        let grainLOD = tip?.grainLOD(pixelAngle: pixelAngle) ?? 0
        for py in y0...y1 {
            for px in x0...x1 {
                // Point du plan tangent, en radians (nord vers le haut de l'image).
                let p = SIMD2<Double>((Double(px) + 0.5 - center.x) * pixelAngle, -(Double(py) + 0.5 - center.y) * pixelAngle)
                var a: Float
                if let tip, let value = tip.shapeValue(at: p, radius: dab.radius, lod: shapeLOD) {
                    a = value
                } else {
                    a = Float(SphericalRasterizer.coverage(distance: simd_length(p), radius: dab.radius,
                                                           hardness: dab.hardness, pixelSize: pixelAngle))
                }
                guard a > 0 else { continue }
                if let tip, let grain = tip.grain {
                    let g: Float
                    if tip.grainMoving {
                        g = tip.grainValue(at: Self.origin, local: p, lod: grainLOD)
                    } else {
                        // Texturé : fixé à l'image, comme il l'est à la sphère.
                        let s = 1 / (tip.grainScale * pixelsPerRadian)
                        g = grain.sample(Double(px) * s, Double(py) * s, wrap: true, lod: grainLOD)
                    }
                    a = tip.applyGrain(a, g)
                }
                StrokeMask.accumulate(&mask[py * width + px], coverage: a, opacity: dab.color.w, flow: dab.flow,
                                      secondary: dab.secondary)
            }
        }
    }

    /// Blanc sur transparent.
    func image() -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let style = style
        for i in 0..<(width * height) {
            // Traits terminés, plus le trait en cours posé par-dessus.
            let stroke = StrokeMask.alpha(mask[i], style: style)
            let a = UInt8(min(1, stroke + committed[i] * (1 - stroke)) * 255 + 0.5)
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
