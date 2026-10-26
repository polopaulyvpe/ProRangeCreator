import PRCore
import simd
import XCTest

final class BrushTipTests: XCTestCase {
    /// Forme 8 × 8 : moitié gauche blanche, moitié droite noire.
    private func halfShape() -> BrushTexture {
        BrushTexture(name: "moitié", size: 8, values: (0..<64).map { $0 % 8 < 4 ? 1 : 0 })
    }

    func testTextureSampling() {
        let t = BrushTexture(name: "t", size: 2, values: [0, 1, 0.5, 0.25])
        XCTAssertEqual(t.sample(0.25, 0.25, wrap: false), 0, accuracy: 1e-6, "centre du texel (0, 0)")
        XCTAssertEqual(t.sample(0.75, 0.75, wrap: false), 0.25, accuracy: 1e-6)
        XCTAssertEqual(t.sample(0.5, 0.25, wrap: false), 0.5, accuracy: 1e-6, "entre deux texels")
        XCTAssertEqual(t.sample(1.25, 0.25, wrap: true), t.sample(0.25, 0.25, wrap: true), accuracy: 1e-6, "répétée")
        XCTAssertEqual(t.sample(0, 0.25, wrap: true), 0.5, accuracy: 1e-6, "bord bouclé")

        let made = BrushTexture.make(name: "m", gray: [Float](repeating: 0.2, count: 30 * 20), width: 30, height: 20, maxSize: 8, invert: true)
        XCTAssertEqual(made.size, 8)
        XCTAssertEqual(made.values[10], 0.8, accuracy: 1e-5)
    }

    func testShapeAndRotationOnTheSphere() {
        let center = Equirect.direction(latitude: 0.3, longitude: 0.5)
        let frame = TangentFrame(center: center)
        let radius = 0.2
        let west = frame.unproject([-0.1, 0])
        let east = frame.unproject([0.1, 0])
        let corner = frame.unproject([-0.18, 0.18]) // dans le carré, hors du disque
        let dab = SphericalDab(center: center, radius: radius, hardness: 1, color: [1, 1, 1, 1], tip: DabTip(shape: halfShape()))
        let evaluator = DabEvaluator(dab, pixelAngle: 0.001)
        XCTAssertEqual(evaluator.coverage(at: west), 1, accuracy: 1e-5, "côté blanc")
        XCTAssertEqual(evaluator.coverage(at: east), 0, accuracy: 1e-5, "côté noir")
        XCTAssertEqual(evaluator.coverage(at: corner), 1, accuracy: 1e-5, "la forme remplit le carré")
        XCTAssertEqual(evaluator.coverage(at: frame.unproject([-0.25, 0])), 0, "hors du carré")

        var turned = dab
        turned.tip?.rotation = .pi
        let rotated = DabEvaluator(turned, pixelAngle: 0.001)
        XCTAssertEqual(rotated.coverage(at: east), 1, accuracy: 1e-5, "demi-tour : le blanc passe à l'est")
        XCTAssertEqual(rotated.coverage(at: west), 0, accuracy: 1e-5)
    }

    func testGrainScalesCoverageAndIsSeamless() {
        let center = Equirect.direction(latitude: 0.1, longitude: 0.2)
        let flat = BrushTexture(name: "gris", size: 4, values: [Float](repeating: 0.5, count: 16))
        let full = SphericalDab(center: center, radius: 0.2, hardness: 1, color: [1, 1, 1, 1], tip: DabTip(grain: flat, grainDepth: 1))
        XCTAssertEqual(DabEvaluator(full, pixelAngle: 0.001).coverage(at: center), 0.5, accuracy: 1e-5, "grain gris : moitié")
        var none = full
        none.tip?.grainDepth = 0
        XCTAssertEqual(DabEvaluator(none, pixelAngle: 0.001).coverage(at: center), 1, accuracy: 1e-5, "profondeur nulle : sans effet")

        // Grain bruité : continu, y compris sur la couture équirectangulaire.
        let noisy = BrushTexture(name: "bruit", size: 16, values: (0..<256).map { Float(($0 * 37) % 101) / 100 })
        let tip = DabTip(grain: noisy, grainScale: 0.3)
        let a = tip.grainValue(at: Equirect.direction(latitude: 0.2, longitude: .pi - 1e-7))
        let b = tip.grainValue(at: Equirect.direction(latitude: 0.2, longitude: -.pi + 1e-7))
        XCTAssertEqual(a, b, accuracy: 1e-4)
    }

    func testSettingsBuildTipsAndStrokeAngle() {
        var settings = BrushSettings.defaultBrush
        XCTAssertNil(settings.dab(at: [0, 0, -1], pressure: 1, color: .one, mode: .paint).tip, "rond classique sans pointe")
        settings.shape = halfShape()
        settings.shapeRotationDegrees = 90
        settings.followStroke = true
        let dab = settings.dab(at: [0, 0, -1], pressure: 1, color: .one, mode: .paint, strokeAngle: 0.5)
        XCTAssertEqual(dab.tip?.rotation ?? 0, .pi / 2 + 0.5, accuracy: 1e-12)

        let center = Equirect.direction(latitude: 0, longitude: 0)
        let frame = TangentFrame(center: center)
        XCTAssertEqual(BrushSettings.strokeAngle(from: frame.unproject([-0.01, 0]), to: center), 0, accuracy: 1e-6, "vers l'est")
        XCTAssertEqual(BrushSettings.strokeAngle(from: frame.unproject([0, -0.01]), to: center), .pi / 2, accuracy: 1e-6, "vers le nord")
    }

    func testJitterAndFlip() {
        var settings = BrushSettings(radiusDegrees: 4, spacing: 0.2)
        settings.shape = halfShape()
        settings.sizeJitter = 0.5
        settings.opacityJitter = 0.5
        settings.scatter = 1
        settings.rotationJitter = .pi
        settings.randomFlip = true
        let center = Equirect.direction(latitude: 0.1, longitude: 0.4)
        let plain = settings.dab(at: center, pressure: 1, color: .one, mode: .paint)
        XCTAssertEqual(plain.radius, settings.radius(pressure: 1), accuracy: 1e-12, "sans tirage : pas de variation")
        XCTAssertLessThan(simd_distance(plain.center, center), 1e-12)

        var a = StrokeRandom(seed: 42), b = StrokeRandom(seed: 42)
        XCTAssertEqual(a.dab(), b.dab(), "reproductible")
        let random = DabRandom(size: 1, opacity: 1, rotation: 1, scatter: 1, flip: true)
        let varied = settings.dab(at: center, pressure: 1, color: .one, mode: .paint, random: random)
        XCTAssertEqual(varied.radius, plain.radius * 0.5, accuracy: 1e-12)
        XCTAssertEqual(varied.color.w, 0.5, accuracy: 1e-6)
        XCTAssertEqual(Sphere.angle(varied.center, center), 2 * varied.radius, accuracy: 1e-9, "dispersion d'un diamètre")
        XCTAssertEqual(varied.tip?.flipX, true)
        XCTAssertEqual(varied.tip?.rotation ?? 0, .pi, accuracy: 1e-12)

        // Miroir : le côté blanc de la forme passe à l'est.
        let frame = TangentFrame(center: center)
        let mirrored = DabEvaluator(SphericalDab(center: center, radius: 0.2, hardness: 1, color: [1, 1, 1, 1],
                                                 tip: DabTip(shape: halfShape(), flipX: true)), pixelAngle: 0.001)
        XCTAssertEqual(mirrored.coverage(at: frame.unproject([0.1, 0])), 1, accuracy: 1e-5)
        XCTAssertEqual(settings.spacing(radius: 1, random: 0.5), 0.2, accuracy: 1e-12)
    }
}
