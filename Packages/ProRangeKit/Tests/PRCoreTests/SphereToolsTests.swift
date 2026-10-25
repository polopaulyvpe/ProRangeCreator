import PRCore
import simd
import XCTest

final class SphereToolsTests: XCTestCase {
    private func assertClose(_ a: Vec3, _ b: Vec3, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_length(a - b), 1e-9, "\(a) ≠ \(b)", file: file, line: line)
    }

    func testSymmetryImages() {
        let d = simd_normalize(Vec3(0.3, 0.4, -0.8))
        XCTAssertEqual(SymmetrySettings().images(of: d).count, 1)

        let vertical = SymmetrySettings(kind: .mirrorVertical).images(of: d)
        XCTAssertEqual(vertical.count, 2)
        assertClose(vertical[1], [-d.x, d.y, d.z]) // axe vers -Z : miroir gauche/droite = x opposé

        let horizon = SymmetrySettings(kind: .mirrorHorizon).images(of: d)
        assertClose(horizon[1], [d.x, -d.y, d.z])

        XCTAssertEqual(SymmetrySettings(kind: .quadrant).images(of: d).count, 4)
        let radial = SymmetrySettings(kind: .radial, count: 6).images(of: d)
        XCTAssertEqual(radial.count, 6)
        for image in radial {
            XCTAssertEqual(image.y, d.y, accuracy: 1e-12, "même latitude")
            XCTAssertEqual(simd_length(image), 1, accuracy: 1e-12)
        }
        XCTAssertEqual(Sphere.angle(radial[0], radial[1]), Sphere.angle(radial[1], radial[2]), accuracy: 1e-12)
        XCTAssertEqual(SymmetrySettings(kind: .kaleidoscope, count: 5).images(of: d).count, 10)

        // Un point du plan miroir est son propre reflet.
        let onPlane = Vec3(0, 0.6, -0.8)
        assertClose(SymmetrySettings(kind: .mirrorVertical).images(of: onPlane)[1], onPlane)
        // L'axe suit la vue : tourné de 90°, le miroir échange avant et arrière.
        let turned = SymmetrySettings(kind: .mirrorVertical, axisYaw: .pi / 2).images(of: [0, 0, -1])
        assertClose(turned[1], [0, 0, 1])
    }

    func testGradientParameter() {
        let a = Equirect.direction(latitude: 0, longitude: 0)
        let b = Equirect.direction(latitude: 0, longitude: 1)
        let linear = SphericalGradient(shape: .linear, start: a, end: b)
        XCTAssertEqual(linear.parameter(at: a), 0, accuracy: 1e-9)
        XCTAssertEqual(linear.parameter(at: b), 1, accuracy: 1e-9)
        XCTAssertEqual(linear.parameter(at: Equirect.direction(latitude: 0, longitude: 0.5)), 0.5, accuracy: 1e-9)
        // Bandes perpendiculaires au grand cercle : un point au nord du milieu garde à peu près le même paramètre.
        XCTAssertEqual(linear.parameter(at: Equirect.direction(latitude: 0.3, longitude: 0.5)), 0.5, accuracy: 0.05)
        XCTAssertEqual(linear.parameter(at: Equirect.direction(latitude: 0, longitude: -0.5)), 0, "avant A : borné à 0")

        let radial = SphericalGradient(shape: .radial, start: a, end: b)
        XCTAssertEqual(radial.parameter(at: Equirect.direction(latitude: 0.5, longitude: 0)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(radial.parameter(at: -a), 1)
    }

    func testRotationBetweenDirections() {
        let a = simd_normalize(Vec3(0.2, 0.5, -0.8))
        let b = simd_normalize(Vec3(-0.7, 0.1, 0.3))
        assertClose(Sphere.rotation(from: a, to: b) * a, b)
        assertClose(Sphere.rotation(from: a, to: a) * a, a)
        assertClose(Sphere.rotation(from: a, to: -a) * a, -a)
        let r = Sphere.rotation(from: a, to: b)
        XCTAssertEqual(simd_determinant(r), 1, accuracy: 1e-9)
    }
}
