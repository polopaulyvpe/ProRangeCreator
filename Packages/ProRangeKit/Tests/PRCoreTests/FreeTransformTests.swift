import PRCore
import simd
import XCTest

/// Transformation libre (Freeform, Uniforme, Déformation, Déformer) : calcul exact, inverses, poignées.
final class FreeTransformTests: XCTestCase {
    private let origin = Equirect.direction(latitude: 0.2, longitude: -0.4)

    private func box() -> FreeTransform {
        FreeTransform(origin: origin, plane: .gnomonic, minX: -0.3, maxX: 0.3, minY: -0.2, maxY: 0.2)
    }

    private var samples: [Vec3] {
        let frame = TangentFrame(center: origin)
        return [[0, 0], [0.1, 0.05], [-0.2, 0.15], [0.25, -0.18], [-0.05, -0.1]].map { frame.fromGnomonic($0) }
    }

    func testIdentityAndFitting() throws {
        let t = box()
        XCTAssertTrue(t.isIdentity)
        for d in samples { XCTAssertLessThan(Sphere.angle(try XCTUnwrap(t.inverse(d)), d), 1e-9) }
        let fitted = try XCTUnwrap(FreeTransform.fitting(samples))
        XCTAssertEqual(fitted.plane, .gnomonic)
        // La boîte contient tous les échantillons.
        for d in samples {
            let p = try XCTUnwrap(fitted.toPlane(d))
            XCTAssertGreaterThanOrEqual(p.x, fitted.sourceOrigin.x)
            XCTAssertLessThanOrEqual(p.x, fitted.sourceOrigin.x + fitted.sourceX.x)
        }
        // Contenu sur plus d'un hémisphère : plan équidistant.
        let wide = try XCTUnwrap(FreeTransform.fitting([origin, -origin + Vec3(0, 0.3, 0), Vec3(0, 1, 0)].map(simd_normalize)))
        XCTAssertEqual(wide.plane, .equidistant)
    }

    func testMatchesOldTransformAndDistort() throws {
        let old = SphericalTransform(origin: origin, target: Equirect.direction(latitude: -0.3, longitude: 1.2), angle: 0.6, scale: [1.4, 0.7])
        let free = FreeTransform(old)
        for d in samples {
            XCTAssertLessThan(Sphere.angle(try XCTUnwrap(free.inverse(d)), old.inverse(d)), 1e-9)
            XCTAssertLessThan(Sphere.angle(try XCTUnwrap(free.apply(d)), old.apply(d)), 1e-9)
        }
        var distort = SphericalDistort(origin: origin, halfAngle: 0.3)
        distort.targetCorners[1] += [0.08, 0.05]
        distort.targetCorners[3] += [-0.04, 0.02]
        let freeDistort = FreeTransform(distort)
        for d in samples {
            XCTAssertLessThan(Sphere.angle(try XCTUnwrap(freeDistort.inverse(d)), try XCTUnwrap(distort.inverse(d))), 1e-9)
        }
    }

    func testRoundTripWithCornersMeshAndMove() throws {
        var t = box()
        t.moveCorner(1, to: t.corners[1] + [0.1, 0.06])
        t.moveEdge(2, by: [0.03, -0.05])
        t.target = Equirect.direction(latitude: 0.5, longitude: 0.3)
        t.warp(grabbed: [0.4, 0.6], to: try XCTUnwrap(t.targetPoint([0.4, 0.6])) + [0.05, 0.03])
        XCTAssertFalse(t.mesh.isIdentity)
        let resolved = try XCTUnwrap(t.resolved())
        for d in samples {
            let moved = try XCTUnwrap(resolved.apply(d))
            XCTAssertLessThan(Sphere.angle(try XCTUnwrap(resolved.inverse(moved)), d), 1e-7)
        }
    }

    func testMeshDragFollowsFinger() throws {
        var mesh = WarpMesh.identity
        let w = SIMD2<Double>(0.3, 0.7)
        mesh.drag(at: w, by: [0.1, -0.05])
        XCTAssertLessThan(simd_distance(mesh.evaluate(w), w + [0.1, -0.05]), 1e-12, "le point attrapé suit exactement")
        XCTAssertLessThan(simd_distance(try XCTUnwrap(mesh.inverse(mesh.evaluate(w))), w), 1e-8)
        // Hors du carré : le déplacement du bord est prolongé, la fonction reste continue.
        XCTAssertLessThan(simd_distance(mesh.evaluate([1.0001, 0.5]), mesh.evaluate([1, 0.5]) + [0.0001, 0]), 1e-9)
        // Coin : seul son point de contrôle bouge.
        var corner = WarpMesh.identity
        corner.drag(at: [0, 0], by: [0.2, 0.1])
        XCTAssertEqual(corner.points[0], [0.2, 0.1])
        XCTAssertEqual(corner.points[1], WarpMesh.identity.points[1])
    }

    func testFlipRotateScaleAndReset() throws {
        var t = box()
        let left = t.fromPlane(t.source([0, 0.5]))
        t.flip(horizontally: true)
        let arrived = try XCTUnwrap(t.apply(left))
        XCTAssertLessThan(Sphere.angle(arrived, t.fromPlane(t.source([1, 0.5]))), 1e-9, "la gauche passe à droite")
        t.flip(horizontally: true)
        XCTAssertTrue(t.isIdentity)

        // Uniforme : le coin bas droit tiré vers l'extérieur, le coin haut gauche reste en place.
        let initial = box()
        var scaled = initial
        let start = initial.corners[2]
        scaled.scale(handle: 2, to: initial.corners[0] + (start - initial.corners[0]) * 2, from: start, initial: initial, uniform: true)
        XCTAssertLessThan(simd_distance(scaled.corners[0], initial.corners[0]), 1e-12)
        XCTAssertLessThan(simd_distance(scaled.corners[2], initial.corners[0] + (start - initial.corners[0]) * 2), 1e-12)
        // Freeform par le milieu du côté droit : seule la largeur change.
        var wide = initial
        wide.scale(handle: 5, to: initial.corners[1] + [0.2, 0.1], from: initial.corners[1], initial: initial, uniform: false)
        XCTAssertEqual(wide.corners[1].y, initial.corners[1].y, accuracy: 1e-12)
        XCTAssertEqual(wide.corners[1].x, initial.corners[1].x + 0.2, accuracy: 1e-12)

        // La boîte seule tourne : le contenu ne bouge pas.
        var turned = box()
        turned.rotate(by: 0.3)
        let before = try XCTUnwrap(turned.resolved())
        turned.rotateBox(by: 0.5)
        let after = try XCTUnwrap(turned.resolved())
        for d in samples {
            XCTAssertLessThan(Sphere.angle(try XCTUnwrap(before.inverse(d)), try XCTUnwrap(after.inverse(d))), 1e-9)
        }
        turned.reset()
        XCTAssertTrue(turned.isIdentity)
    }
}
