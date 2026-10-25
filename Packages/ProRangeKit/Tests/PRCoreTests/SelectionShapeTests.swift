import PRCore
import simd
import XCTest

final class SelectionShapeTests: XCTestCase {
    func testShapesContainment() {
        let rect = SelectionShape.rectangle([0.2, 0.5], [-0.2, -0.5])
        XCTAssertTrue(rect.contains([0, 0]))
        XCTAssertFalse(rect.contains([0.3, 0]))
        let ellipse = SelectionShape.ellipse([-0.4, -0.2], [0.4, 0.2])
        XCTAssertTrue(ellipse.contains([0.39, 0]))
        XCTAssertFalse(ellipse.contains([0.39, 0.19]), "coin du rectangle englobant : hors de l'ellipse")
        let triangle = SelectionShape.polygon([[0, 0.5], [-0.5, -0.5], [0.5, -0.5]])
        XCTAssertTrue(triangle.contains([0, 0]))
        XCTAssertFalse(triangle.contains([0.45, 0.4]))
        XCTAssertFalse(SelectionShape.polygon([[0, 0], [1, 1]]).contains([0.5, 0.5]))
    }

    func testCombineModes() {
        XCTAssertEqual(SelectionCombine.replace.combine(0.8, 0.2), 0.2)
        XCTAssertEqual(SelectionCombine.add.combine(0.8, 0.2), 0.8)
        XCTAssertEqual(SelectionCombine.subtract.combine(0.8, 1), 0)
        XCTAssertEqual(SelectionCombine.subtract.combine(0.8, 0.25), 0.75)
    }

    /// `ndc(of:)` est l'inverse exact de `direction(ndc:)` en vue rectiligne, fenêtre plane et vue dépliée.
    func testScreenProjectionRoundTrip() throws {
        var view = ViewState()
        view.yaw = 0.8
        view.pitch = -0.3
        let points: [SIMD2<Double>] = [[0, 0], [0.7, -0.4], [-0.9, 0.95]]
        for p in points {
            let parameters = view.parameters(aspect: 1.4)
            let d = try XCTUnwrap(parameters.direction(ndc: p))
            let back = try XCTUnwrap(parameters.ndc(of: d))
            XCTAssertLessThan(simd_distance(back, p), 1e-9)
        }
        XCTAssertNil(view.parameters(aspect: 1.4).ndc(of: -view.direction(atNDC: .zero, aspect: 1.4)!), "derrière la caméra")

        view.showFace(.up)
        view.flatShift = [0.1, -0.2]
        let flat = view.parameters(aspect: 1.4)
        let back = try XCTUnwrap(flat.ndc(of: try XCTUnwrap(flat.direction(ndc: [0.3, 0.3]))))
        XCTAssertLessThan(simd_distance(back, [0.3, 0.3]), 1e-9)

        view.mode = .unfolded
        view.morph = 1
        view.unfoldedCenter = [0.97, 0.4] // près de la couture
        view.unfoldedSpan = 0.6
        let unfolded = view.parameters(aspect: 2)
        for p in points {
            guard let d = unfolded.direction(ndc: p) else { continue }
            let back = try XCTUnwrap(unfolded.ndc(of: d))
            XCTAssertLessThan(simd_distance(back, p), 1e-9, "\(p)")
        }
    }

    func testSphericalTransform() {
        let origin = Equirect.direction(latitude: 0.3, longitude: 0.5)
        let target = Equirect.direction(latitude: -0.4, longitude: 2.5)
        var t = SphericalTransform(origin: origin, target: target, angle: 0.7, scale: [1.5, 0.8])
        XCTAssertFalse(t.isIdentity)
        XCTAssertLessThan(simd_distance(t.apply(origin), target), 1e-9, "l'origine arrive sur la cible")
        for d in [Equirect.direction(latitude: 0.35, longitude: 0.55), Equirect.direction(latitude: 0.1, longitude: 0.2)] {
            XCTAssertLessThan(simd_distance(t.inverse(t.apply(d)), d), 1e-9)
        }
        t = SphericalTransform(origin: origin, scale: [2, 2])
        let near = Equirect.direction(latitude: 0.35, longitude: 0.5)
        XCTAssertEqual(Sphere.angle(origin, t.apply(near)), 2 * Sphere.angle(origin, near), accuracy: 1e-9)
        XCTAssertTrue(SphericalTransform(origin: origin).isIdentity)
    }
}
