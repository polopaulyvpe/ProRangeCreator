import PRCore
import simd
import XCTest

/// Dynamique de couleur, mélange humide, couleur par texel du masque de trait, réglages Apple Pencil.
final class PaintDynamicsTests: XCTestCase {
    private let blue: SIMD3<Float> = [0.05, 0.2, 0.8]
    private let yellow: SIMD3<Float> = [0.9, 0.8, 0.1]
    private let shape = BrushTexture(name: "barre", size: 8, values: (0..<64).map { $0 % 8 < 4 ? 1 : 0.2 })

    private func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ accuracy: Float = 1e-4,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_reduce_max(simd_abs(a - b)), accuracy, "\(a) ≠ \(b)", file: file, line: line)
    }

    // MARK: Couleur par texel

    func testDepositColorOnFreshTexelIsExact() {
        var c = SIMD3<Float>(repeating: .nan)
        StrokeMask.depositColor(&c, mask: .zero, coverage: 0.3, opacity: 0.5, flow: 0.2, color: blue)
        XCTAssertEqual(c, blue, "texel vierge : couleur posée telle quelle, l'ancien contenu ignoré")
    }

    func testDepositColorOverFullGlazeKeepsStampStrength() {
        var c = blue
        // Masque déjà plein : le tampon n'ajoute rien, mais recouvre la couleur selon son opacité × flux.
        StrokeMask.depositColor(&c, mask: [1, 1, 0, 0], coverage: 1, opacity: 0.5, flow: 0.5, color: yellow)
        assertClose(c, blue + (yellow - blue) * 0.25)
        // Un tampon plein remplace la couleur.
        StrokeMask.depositColor(&c, mask: [1, 1, 0, 0], coverage: 1, opacity: 1, flow: 1, color: yellow)
        XCTAssertEqual(c, yellow)
    }

    // MARK: Dynamique de couleur

    func testNeutralSettingsKeepColor() {
        let brush = BrushSettings()
        XCTAssertFalse(brush.hasColorDynamics)
        let out = ColorDynamics.apply(blue, secondary: yellow, brush: brush, stamp: .none, stroke: .none, pressure: 0.3, tilt: 0.4)
        assertClose(out, blue, 1e-3)
    }

    func testPressureMovesToSecondaryColor() {
        var brush = BrushSettings()
        brush.pressureSecondary = 1
        XCTAssertTrue(brush.varyingColor)
        assertClose(ColorDynamics.apply(blue, secondary: yellow, brush: brush, stamp: .none, stroke: .none, pressure: 1, tilt: 0), yellow, 1e-3)
        assertClose(ColorDynamics.apply(blue, secondary: yellow, brush: brush, stamp: .none, stroke: .none, pressure: 0, tilt: 0), blue, 1e-3)
    }

    func testDarknessAndHueJitter() {
        var brush = BrushSettings()
        brush.stampDarknessJitter = 1
        let dark = ColorDynamics.apply(blue, secondary: yellow, brush: brush, stamp: ColorDraw(darkness: 1), stroke: .none,
                                       pressure: 1, tilt: 0)
        assertClose(dark, .zero)
        brush.stampDarknessJitter = 0
        brush.stampHueJitter = 1
        let shifted = ColorDynamics.apply(blue, secondary: yellow, brush: brush, stamp: ColorDraw(hue: 1), stroke: .none,
                                          pressure: 1, tilt: 0)
        let before = HSBColor(rgb: SIMD3<Double>(ColorTransfer.toEncoded(blue)))
        let after = HSBColor(rgb: SIMD3<Double>(ColorTransfer.toEncoded(shifted)))
        var delta = abs(after.hue - before.hue)
        delta = min(delta, 1 - delta)
        XCTAssertEqual(delta, 0.5, accuracy: 0.01, "100 % de variation au tirage maximal : la moitié du cercle")
        XCTAssertEqual(after.saturation, before.saturation, accuracy: 0.01)
    }

    func testDabCarriesDynamicColor() {
        var brush = BrushSettings()
        brush.pressureSecondary = 1
        brush.pressureAffectsSize = false
        let dab = brush.dab(at: [0, 0, -1], pressure: 1, color: blue, mode: .paint,
                            context: StrokeContext(secondaryColor: yellow))
        assertClose(SIMD3(dab.color.x, dab.color.y, dab.color.z), yellow, 1e-3)
        XCTAssertTrue(brush.strokeStyle(color: blue, mode: .paint).varyingColor)
        XCTAssertFalse(brush.strokeStyle(color: blue, mode: .erase).varyingColor, "la gomme n'a pas de couleur")
    }

    // MARK: Mélange humide

    private func wetDab() -> SphericalDab {
        SphericalDab(center: [0, 0, -1], radius: 0.01, hardness: 1, color: SIMD4<Float>(blue.x, blue.y, blue.z, 1))
    }

    func testPullTakesCanvasColor() {
        var brush = BrushSettings()
        brush.wetPull = 1
        XCTAssertTrue(brush.wetMixActive)
        var mixer = WetMixer()
        let canvas = SIMD4<Float>(yellow.x, yellow.y, yellow.z, 1)
        var last = wetDab()
        for _ in 0..<12 {
            last = wetDab()
            mixer.apply(&last, brush: brush, distance: 0, pickup: canvas, wide: canvas, random: .none)
        }
        assertClose(SIMD3(last.color.x, last.color.y, last.color.z), yellow, 0.02)
        // Sur une toile vide, la couleur du pinceau reste.
        var fresh = WetMixer()
        var dab = wetDab()
        fresh.apply(&dab, brush: brush, distance: 0, pickup: .zero, wide: .zero, random: .none)
        assertClose(SIMD3(dab.color.x, dab.color.y, dab.color.z), blue)
    }

    func testDilutionAndChargeFadeTheStroke() {
        var brush = BrushSettings()
        brush.wetDilution = 0.6
        brush.wetCharge = 0.2
        brush.wetAttack = 1
        var mixer = WetMixer()
        var start = wetDab(), later = wetDab()
        mixer.apply(&start, brush: brush, distance: 0, pickup: .zero, wide: .zero, random: .none)
        mixer.apply(&later, brush: brush, distance: 0.5, pickup: .zero, wide: .zero, random: .none)
        XCTAssertLessThan(start.color.w, 1, "diluée : transparente")
        XCTAssertGreaterThan(start.color.w, 0.4)
        XCTAssertLessThan(later.color.w, start.color.w * 0.1, "le pinceau se vide le long du trait")
    }

    // MARK: Apple Pencil

    func testShapeFollowsAzimuth() {
        var brush = BrushSettings()
        brush.shape = shape
        brush.followStroke = true
        brush.azimuthRotation = true
        let withPencil = brush.dab(at: [0, 0, -1], pressure: 1, color: blue, mode: .paint, strokeAngle: 0.3,
                                   context: StrokeContext(azimuth: 1.2))
        XCTAssertEqual(withPencil.tip?.rotation ?? 0, 1.2, accuracy: 1e-12)
        let withFinger = brush.dab(at: [0, 0, -1], pressure: 1, color: blue, mode: .paint, strokeAngle: 0.3)
        XCTAssertEqual(withFinger.tip?.rotation ?? 0, 0.3, accuracy: 1e-12, "au doigt : la rotation suivant le trait")
    }

    func testRoundnessBleedAndGradation() {
        var brush = BrushSettings(hardness: 0.8)
        brush.shape = shape
        brush.pressureRoundness = 0.5
        brush.pressureBleed = 1
        brush.grainDepth = 0.4
        brush.tiltGradation = 1
        let light = brush.dab(at: [0, 0, -1], pressure: 0, color: blue, mode: .paint)
        XCTAssertEqual(light.tip?.roundness ?? 0, 0.5, accuracy: 1e-12)
        XCTAssertEqual(light.hardness, 0, accuracy: 1e-12, "bavure pleine à pression nulle")
        let full = brush.dab(at: [0, 0, -1], pressure: 1, color: blue, mode: .paint)
        XCTAssertEqual(full.tip?.roundness ?? 0, 1, accuracy: 1e-12)
        XCTAssertEqual(full.hardness, 0.8, accuracy: 1e-12)
        let tilted = brush.dab(at: [0, 0, -1], pressure: 1, color: blue, mode: .paint, context: StrokeContext(tilt: 1))
        XCTAssertEqual(tilted.hardness, 0, accuracy: 1e-12, "dégradé : bord adouci, Pencil couché")
    }

    func testAzimuthInterpolationTakesShortestPath() {
        var sampler = SplineStrokeSampler(onSphere: false)
        var out = sampler.begin(StrokeSample(point: [0, 0, 0], pressure: 1, azimuth: 3.0))
        out += sampler.add(StrokeSample(point: [10, 0, 0], pressure: 1, azimuth: -3.0)) { _ in 1 }
        out += sampler.finish { _ in 1 }
        XCTAssertGreaterThan(out.count, 5)
        for sample in out {
            XCTAssertNotNil(sample.azimuth)
            XCTAssertLessThan(cos(sample.azimuth ?? 0), -0.98, "de 3 à −3 radians en passant par π, pas par 0")
        }
    }
}
