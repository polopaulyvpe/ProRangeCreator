import PRCore
import simd
import XCTest

final class PaintingTests: XCTestCase {
    func testTransferIsContinuousAndReversibleBeyondOne() {
        XCTAssertEqual(ColorTransfer.toEncoded(1), 1, accuracy: 1e-5)
        XCTAssertEqual(ColorTransfer.toEncoded(1.0001), 1 + 0.0001 * 1.055 / 2.4, accuracy: 1e-5, "prolongement linéaire de même pente")
        for v: Float in [0, 0.001, 0.2, 0.9, 1, 1.5, 4, 32, 1000, -0.3] {
            XCTAssertEqual(ColorTransfer.toLinear(ColorTransfer.toEncoded(v)), v, accuracy: max(1e-5, abs(v) * 1e-5), "\(v)")
        }
    }

    func testPerceptualBlendMatchesProcreateMidGray() {
        // Noir à 50 % sur blanc : 0,5 encodé, soit ~0,214 linéaire (en lumière linéaire, ce serait 0,5).
        var perceptual = SIMD4<Float>(1, 1, 1, 1)
        SphericalRasterizer.blendPerceptual([0, 0, 0, 0.5], coverage: 1, into: &perceptual)
        XCTAssertEqual(perceptual.x, ColorTransfer.toLinear(0.5), accuracy: 1e-5)
        XCTAssertEqual(perceptual.w, 1, accuracy: 1e-6)

        var linear = SIMD4<Float>(1, 1, 1, 1)
        SphericalRasterizer.blend([0, 0, 0, 0.5], coverage: 1, into: &linear)
        XCTAssertEqual(linear.x, 0.5, accuracy: 1e-6)
    }

    func testBlendsAgreeOnEmptyAndOpaque() {
        for space in BlendSpace.allCases {
            let dab = SphericalDab(center: [0, 0, -1], radius: 1, hardness: 1, color: [0.3, 0.6, 2.0, 1])
            var empty = SIMD4<Float>.zero
            SphericalRasterizer.apply(dab, coverage: 0.4, to: &empty, space: space)
            XCTAssertEqual(empty.w, 0.4, accuracy: 1e-6)
            XCTAssertEqual(empty.z / empty.w, 2.0, accuracy: 1e-4, "\(space) : couleur intacte sur un fond vide")

            var covered = SIMD4<Float>(0.1, 0.1, 0.1, 1)
            SphericalRasterizer.apply(dab, coverage: 1, to: &covered, space: space)
            XCTAssertEqual(covered.z, 2.0, accuracy: 1e-4, "\(space) : un dab opaque recouvre tout")
        }
    }

    func testEraserRemovesProportionally() {
        let eraser = SphericalDab(center: [0, 0, -1], radius: 1, hardness: 1, color: [0, 0, 0, 0.5], mode: .erase)
        var p = SIMD4<Float>(0.4, 0.2, 0.1, 0.8)
        SphericalRasterizer.apply(eraser, coverage: 1, to: &p, space: .perceptual)
        XCTAssertEqual(p, SIMD4<Float>(0.2, 0.1, 0.05, 0.4))
    }

    func testPressureDynamics() {
        var settings = BrushSettings(radiusDegrees: 10, opacity: 0.8, minimumSize: 0.2)
        XCTAssertEqual(settings.radius(pressure: 1), 10 * .pi / 180, accuracy: 1e-12)
        XCTAssertEqual(settings.radius(pressure: 0), 2 * .pi / 180, accuracy: 1e-12)
        XCTAssertEqual(settings.opacity(pressure: 0.3), 0.8, "opacité fixe par défaut")
        settings.pressureAffectsOpacity = true
        settings.pressureAffectsSize = false
        XCTAssertEqual(settings.opacity(pressure: 0.5), 0.4, accuracy: 1e-12)
        XCTAssertEqual(settings.radius(pressure: 0.1), 10 * .pi / 180, accuracy: 1e-12)
        XCTAssertEqual(settings.radius(pressure: 7), 10 * .pi / 180, accuracy: 1e-12, "pression bornée")
        let dab = settings.dab(at: [0, 1, 0], pressure: 0.5, color: [1, 0, 0], mode: .erase)
        XCTAssertEqual(dab.color.w, 0.4, accuracy: 1e-6)
        XCTAssertEqual(dab.mode, .erase)
    }

    func testHSBAndHexRoundTrip() throws {
        for c: SIMD3<Double> in [[1, 0, 0], [0.2, 0.6, 0.4], [0.5, 0.5, 0.5], [0, 0, 0], [0.9, 0.1, 0.8]] {
            let back = HSBColor(rgb: c).rgb
            XCTAssertLessThan(simd_length(back - c), 1e-9, "\(c)")
        }
        XCTAssertEqual(HSBColor(rgb: [0, 1, 0]).hue, 1.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(HexColor.format([1, 0.5, 0]), "#FF8000")
        let parsed = try XCTUnwrap(HexColor.parse(" #ff8000 "))
        XCTAssertEqual(parsed.x, 1)
        XCTAssertEqual(parsed.y, 128.0 / 255, accuracy: 1e-12)
        XCTAssertEqual(HexColor.parse("0f0"), [0, 1, 0])
        XCTAssertNil(HexColor.parse("#12345"))
        XCTAssertNil(HexColor.parse("zzzzzz"))
    }
}
