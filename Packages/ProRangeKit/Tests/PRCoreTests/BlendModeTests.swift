import PRCore
import simd
import XCTest

final class BlendModeTests: XCTestCase {
    private func gray(_ v: Float) -> SIMD3<Float> { SIMD3<Float>(repeating: v) }

    private func assertMode(_ mode: BlendMode, _ b: Float, _ s: Float, _ expected: Float,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(mode.blend(gray(b), gray(s)).x, expected, accuracy: 1e-5, "\(mode)(\(b), \(s))", file: file, line: line)
    }

    func testSeparableModes() {
        assertMode(.normal, 0.3, 0.7, 0.7)
        assertMode(.multiply, 0.5, 0.5, 0.25)
        assertMode(.screen, 0.5, 0.5, 0.75)
        assertMode(.darken, 0.3, 0.7, 0.3)
        assertMode(.lighten, 0.3, 0.7, 0.7)
        assertMode(.overlay, 0.25, 0.8, 0.4)
        assertMode(.hardLight, 0.8, 0.25, 0.4)
        assertMode(.softLight, 0.5, 0.5, 0.5)
        assertMode(.softLight, 0.25, 1, 0.5)
        assertMode(.colorDodge, 0.5, 0.5, 1)
        assertMode(.colorBurn, 0.5, 0.5, 0)
        assertMode(.vividLight, 0.5, 0.75, 1)
        assertMode(.linearLight, 0.5, 0.6, 0.7)
        assertMode(.pinLight, 0.8, 0.2, 0.4)
        assertMode(.hardMix, 0.6, 0.5, 1)
        assertMode(.hardMix, 0.4, 0.5, 0)
        assertMode(.difference, 0.2, 0.7, 0.5)
        assertMode(.exclusion, 0.5, 0.5, 0.5)
        assertMode(.linearBurn, 0.3, 0.4, 0)
        assertMode(.subtract, 0.3, 0.5, 0)
        assertMode(.divide, 0.5, 0.25, 2)
        assertMode(.divide, 0.5, 0, 65504)
    }

    func testHDRBehaviour() {
        // Non bornés : les valeurs > 1 passent.
        assertMode(.add, 0.8, 0.7, 1.5)
        assertMode(.multiply, 2, 0.5, 1)
        assertMode(.lighten, 3, 0.5, 3)
        // Bornés : écrêtés à [0, 1] avant le calcul.
        assertMode(.screen, 2, 0.5, 1)
        assertMode(.overlay, 4, 4, 1)
        XCTAssertFalse(BlendMode.add.isBounded)
        XCTAssertTrue(BlendMode.softLight.isBounded)
    }

    func testNonSeparableModesKeepLuminosityRules() {
        let b = SIMD3<Float>(0.8, 0.3, 0.2)
        let s = SIMD3<Float>(0.1, 0.4, 0.9)
        func lum(_ c: SIMD3<Float>) -> Float { 0.3 * c.x + 0.59 * c.y + 0.11 * c.z }
        XCTAssertEqual(lum(BlendMode.luminosity.blend(b, s)), lum(s), accuracy: 1e-5)
        XCTAssertEqual(lum(BlendMode.color.blend(b, s)), lum(b), accuracy: 1e-5)
        XCTAssertEqual(lum(BlendMode.hue.blend(b, s)), lum(b), accuracy: 1e-5)
        XCTAssertEqual(lum(BlendMode.saturation.blend(b, s)), lum(b), accuracy: 1e-5)
        let grayResult = BlendMode.saturation.blend(b, gray(0.5))
        XCTAssertEqual(grayResult.x, grayResult.y, accuracy: 1e-5, "saturation d'un gris : résultat gris")
        XCTAssertEqual(BlendMode.darkerColor.blend(b, s), lum(s) < lum(b) ? s : b)
    }

    /// Les codes et la liste des modes non bornés sont recopiés dans le shader : ils doivent rester identiques.
    func testCodesMatchShader() {
        XCTAssertEqual(BlendMode.allCases.count, 26)
        XCTAssertEqual(BlendMode.normal.code, 0)
        XCTAssertEqual(BlendMode.luminosity.code, 25)
        let unbounded = Set(BlendMode.allCases.filter { !$0.isBounded }.map(\.code))
        XCTAssertEqual(unbounded, [0, 1, 2, 4, 5, 6, 9, 10, 18, 20, 21])
    }

    func testCompositing() {
        let white = SIMD4<Float>(1, 1, 1, 1)
        // Noir à 50 % en Normal, façon Procreate : gris 0,5 encodé.
        let half = Compositing.composite(white, [0, 0, 0, 1], mode: .normal, opacity: 0.5, space: .perceptual)
        XCTAssertEqual(half.x, ColorTransfer.toLinear(0.5), accuracy: 1e-5)
        XCTAssertEqual(half.w, 1)
        // Produit par du blanc : rien ne change.
        let color = SIMD4<Float>(0.2, 0.4, 0.6, 1)
        let multiplied = Compositing.composite(color, white, mode: .multiply, opacity: 1, space: .perceptual)
        XCTAssertLessThan(simd_length(multiplied - color), 1e-5)
        // Sur du transparent, tous les modes montrent la source.
        for mode in BlendMode.allCases {
            let r = Compositing.composite(.zero, [0.1, 0.2, 0.3, 0.5], mode: mode, opacity: 1, space: .linear)
            XCTAssertLessThan(simd_length(r - SIMD4<Float>(0.1, 0.2, 0.3, 0.5)), 1e-5, "\(mode)")
        }
        // Source transparente ou opacité nulle : rien ne change.
        XCTAssertEqual(Compositing.composite(color, .zero, mode: .screen, opacity: 1, space: .perceptual), color)
        XCTAssertEqual(Compositing.composite(color, white, mode: .screen, opacity: 0, space: .perceptual), color)
    }

    /// Le pinceau (source-over perceptuel) et la composition d'un calque Normal donnent la même chose.
    func testNormalCompositingMatchesBrush() {
        let dst = SIMD4<Float>(0.3, 0.2, 0.1, 0.6)
        let brushColor = SIMD4<Float>(0.9, 0.5, 0.2, 0.8)
        let coverage: Float = 0.7
        var brushed = dst
        SphericalRasterizer.blendPerceptual(brushColor, coverage: coverage, into: &brushed)
        let a = coverage * brushColor.w
        let source = SIMD4<Float>(brushColor.x * a, brushColor.y * a, brushColor.z * a, a)
        let composited = Compositing.composite(dst, source, mode: .normal, opacity: 1, space: .perceptual)
        XCTAssertLessThan(simd_length(brushed - composited), 1e-5)
    }

    func testAlphaLockKeepsTransparency() {
        let dab = SphericalDab(center: [0, 0, -1], radius: 1, hardness: 1, color: [1, 0, 0, 1])
        var empty = SIMD4<Float>.zero
        SphericalRasterizer.apply(dab, coverage: 1, to: &empty, space: .perceptual, alphaLock: true)
        XCTAssertEqual(empty, .zero, "rien là où il n'y avait rien")
        var painted = SIMD4<Float>(0, 0, 0.25, 0.5)
        SphericalRasterizer.apply(dab, coverage: 1, to: &painted, space: .perceptual, alphaLock: true)
        XCTAssertEqual(painted.w, 0.5, accuracy: 1e-6)
        XCTAssertEqual(painted.x, 0.5, accuracy: 1e-5, "couleur remplacée, transparence gardée")
    }
}
