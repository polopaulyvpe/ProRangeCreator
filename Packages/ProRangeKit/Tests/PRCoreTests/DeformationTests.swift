import PRCore
import simd
import XCTest

final class DeformationTests: XCTestCase {
    func testGnomonicRoundTrip() throws {
        let frame = TangentFrame(center: Equirect.direction(latitude: 0.4, longitude: 1.1))
        let d = Equirect.direction(latitude: 0.6, longitude: 1.3)
        let g = try XCTUnwrap(frame.gnomonic(d))
        XCTAssertLessThan(simd_distance(frame.fromGnomonic(g), d), 1e-12)
        XCTAssertNil(frame.gnomonic(-frame.center), "hémisphère opposé")
    }

    func testHomographyFromCorners() throws {
        let square: [SIMD2<Double>] = [[-1, 1], [1, 1], [1, -1], [-1, -1]]
        let quad: [SIMD2<Double>] = [[-1.2, 1.5], [0.9, 1.1], [1.4, -0.8], [-0.7, -1.3]]
        let h = try XCTUnwrap(Homography(from: square, to: quad))
        for (s, q) in zip(square, quad) {
            XCTAssertLessThan(simd_distance(try XCTUnwrap(h.apply(s)), q), 1e-9)
        }
        let p = SIMD2<Double>(0.3, -0.2)
        XCTAssertLessThan(simd_distance(try XCTUnwrap(h.inverse.apply(try XCTUnwrap(h.apply(p)))), p), 1e-9)
        let identity = try XCTUnwrap(Homography(from: square, to: square))
        XCTAssertLessThan(simd_distance(try XCTUnwrap(identity.apply(p)), p), 1e-9)
        XCTAssertNil(Homography(from: [[0, 0], [1, 1], [2, 2], [3, 3]], to: quad), "points alignés")
    }

    func testDistortInverse() throws {
        let origin = Equirect.direction(latitude: 0.2, longitude: -0.5)
        var distort = SphericalDistort(origin: origin, halfAngle: 0.3)
        let inside = Equirect.direction(latitude: 0.25, longitude: -0.45)
        XCTAssertLessThan(simd_distance(try XCTUnwrap(distort.inverse(inside)), inside), 1e-9, "sans coin déplacé : identité")
        // Tous les coins décalés du même angle vers l'est : le contenu suit (déplacement de ~0,1 rad).
        for i in 0..<4 {
            let corner = distort.targetDirections[i]
            distort.moveCorner(i, to: Sphere.rotation(from: origin, to: Equirect.direction(latitude: 0.2, longitude: -0.4)) * corner)
        }
        let moved = try XCTUnwrap(distort.inverse(Equirect.direction(latitude: 0.2, longitude: -0.4)))
        XCTAssertLessThan(Sphere.angle(moved, origin), 0.02)
        XCTAssertNil(distort.inverse(-origin))
    }

    func testQuickShapeRecognition() throws {
        let a = Equirect.direction(latitude: 0.1, longitude: -0.5)
        let b = Equirect.direction(latitude: 0.3, longitude: 0.6)
        // Ligne tremblée.
        let wobbly = (0...30).map { i -> Vec3 in
            let p = Sphere.slerp(a, b, Double(i) / 30)
            return simd_normalize(p + Vec3(0, 0.01 * sin(Double(i)), 0))
        }
        guard case let .line(start, end)? = QuickShape.fit(wobbly) else { return XCTFail("ligne attendue") }
        XCTAssertLessThan(Sphere.angle(start, a), 0.05)
        XCTAssertLessThan(Sphere.angle(end, b), 0.05)

        // Cercle approximatif, fermé.
        let center = Equirect.direction(latitude: 0.4, longitude: 2)
        let frame = TangentFrame(center: center)
        let ring = (0...40).map { i -> Vec3 in
            let t = 2 * Double.pi * Double(i) / 40
            return frame.unproject(SIMD2<Double>(cos(t), sin(t)) * (0.3 + 0.01 * sin(3 * t)))
        }
        guard case let .circle(c, r)? = QuickShape.fit(ring) else { return XCTFail("cercle attendu") }
        XCTAssertLessThan(Sphere.angle(c, center), 0.02)
        XCTAssertEqual(r, 0.3, accuracy: 0.02)
        let points = QuickShape.circle(center: c, radius: r).points(spacing: 0.05)
        XCTAssertGreaterThan(points.count, 30)
        for p in points { XCTAssertEqual(Sphere.angle(p, c), r, accuracy: 1e-9) }

        // Gribouillis : rien.
        let scribble = (0...30).map { i in Equirect.direction(latitude: 0.3 * sin(Double(i) * 1.7), longitude: 0.4 * cos(Double(i) * 2.3)) }
        XCTAssertNil(QuickShape.fit(scribble))
    }
}
