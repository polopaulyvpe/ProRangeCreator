import Foundation
import simd
import XCTest
@testable import PRCore

final class Drawing360Tests: XCTestCase {
    // MARK: - Perspective

    func testLockedStrokeStaysOnCircleThroughVanishingPoint() throws {
        var settings = PerspectiveSettings()
        let vanishing = simd_normalize(Vec3(0.3, 0.1, -1))
        settings.points = [VanishingPoint(direction: vanishing, isFree: true)]
        let start = simd_normalize(Vec3(-0.5, 0.4, -1))
        let lock = try XCTUnwrap(settings.lock(from: start, through: simd_normalize(start + vanishing * 0.1)))
        XCTAssertEqual(simd_dot(lock.normal, vanishing), 0, accuracy: 1e-12, "le cercle passe par le point de fuite")
        XCTAssertEqual(simd_dot(lock.normal, -vanishing), 0, accuracy: 1e-12, "et par son opposé")
        XCTAssertEqual(simd_dot(lock.normal, start), 0, accuracy: 1e-12, "et par le départ du trait")
        for k in 0..<200 {
            let wild = simd_normalize(Vec3(sin(Double(k) * 7.1), cos(Double(k) * 3.3), sin(Double(k) * 1.9) + 0.01))
            let locked = lock.apply(wild)
            XCTAssertEqual(simd_length(locked), 1, accuracy: 1e-9)
            XCTAssertEqual(simd_dot(locked, lock.normal), 0, accuracy: 1e-9)
        }
        XCTAssertEqual(lock.apply(lock.normal), start, "au pôle du cercle, repli sur le départ")
    }

    func testLockFollowsTheGestureDirection() throws {
        var settings = PerspectiveSettings()
        settings.points = PerspectiveSettings.boxPoints(yaw: 0)
        let start = simd_normalize(Vec3(0.4, 0.3, -1))
        // Geste vers le haut : l'axe vertical, donc un cercle passant par le zénith.
        let up = try XCTUnwrap(settings.lock(from: start, through: simd_normalize(start + Vec3(0, 0.05, 0))))
        XCTAssertEqual(simd_dot(up.normal, [0, 1, 0]), 0, accuracy: 1e-9)
        // Geste vers le point de fuite d'en face.
        let front = Vec3(0, 0, -1)
        let ahead = try XCTUnwrap(settings.lock(from: start, through: simd_normalize(start + (front - start) * 0.05)))
        XCTAssertEqual(simd_dot(ahead.normal, front), 0, accuracy: 1e-9)
    }

    func testLockIgnoresVanishingPointUnderTheStart() {
        var settings = PerspectiveSettings()
        let start = Vec3(0, 0, -1)
        settings.points = [VanishingPoint(direction: start, isFree: true)]
        XCTAssertNil(settings.lock(from: start, through: simd_normalize(Vec3(0.1, 0, -1))), "trait libre")
    }

    func testBoxStaysOrthogonalAndUprightWhenMoved() {
        var settings = PerspectiveSettings()
        settings.points = PerspectiveSettings.boxPoints(yaw: 0.4)
        let front = settings.points[0]
        settings.move(front.id, to: simd_normalize(Vec3(1, 0.5, -1)))
        let p = settings.points.map(\.direction)
        XCTAssertEqual(simd_dot(p[0], p[1]), 0, accuracy: 1e-9)
        XCTAssertEqual(p[2].y, 1, accuracy: 1e-9, "la verticale reste verticale")
        XCTAssertEqual(p[0].y, 0, accuracy: 1e-9)
        XCTAssertEqual(atan2(p[0].z, p[0].x), atan2(-1.0, 1.0), accuracy: 1e-9, "le lacet suit la poignée")
        settings.move(settings.points[2].id, to: [0.5, 0.5, 0.5])
        XCTAssertEqual(settings.points.map(\.direction), p, "l'axe vertical ne bouge pas")
    }

    func testFreeTiltAndFreePoint() {
        var settings = PerspectiveSettings()
        settings.keepsVerticals = false
        settings.points = PerspectiveSettings.boxPoints(yaw: 0)
        let free = VanishingPoint(direction: [0.5, 0.2, 0.8], isFree: true)
        settings.points.append(free)
        let target = simd_normalize(Vec3(0.2, 0.6, -1))
        settings.move(settings.points[0].id, to: target)
        let p = settings.points.map(\.direction)
        XCTAssertEqual(simd_distance(p[0], target), 0, accuracy: 1e-9)
        XCTAssertEqual(simd_dot(p[1], p[2]), 0, accuracy: 1e-9, "le repère reste rigide")
        XCTAssertEqual(p[3], free.direction, "un point libre ne suit pas le repère")
        settings.move(free.id, to: [1, 0, 0])
        XCTAssertEqual(settings.points[3].direction, [1, 0, 0])
        XCTAssertEqual(settings.points[0].direction, p[0], "et le repère ne suit pas un point libre")
    }

    func testGridCirclesPassThroughAxis() {
        let axis = simd_normalize(Vec3(0.2, 0.9, -0.3))
        let normals = PerspectiveSettings.circleNormals(through: axis, count: 12)
        XCTAssertEqual(normals.count, 12)
        for normal in normals {
            XCTAssertEqual(simd_dot(normal, axis), 0, accuracy: 1e-12)
            for point in PerspectiveSettings.circle(normal: normal, samples: 16) {
                XCTAssertEqual(simd_dot(point, normal), 0, accuracy: 1e-12)
            }
        }
    }

    // MARK: - Plan

    func testForeshorteningMatchesPlaneGeometry() throws {
        let plane = PaintPlane(normal: [0, -1, 0])
        let color = SIMD4<Float>(1, 1, 1, 1)
        var atFoot = SphericalDab(center: [0, -1, 0], radius: 0.1, hardness: 1, color: color)
        PaintPlane.foreshorten(&atFoot, normal: plane.normal)
        XCTAssertEqual(atFoot.radius, 0.1, accuracy: 1e-12, "au pied du plan, la taille réglée")
        XCTAssertNil(atFoot.squash, "et un tampon rond")

        // Un petit tampon rond posé réellement sur le sol y = −1, regardé depuis le centre.
        let center = simd_normalize(Vec3(1.2, -1, 0.4))
        let onFloor = center / -center.y
        var dab = SphericalDab(center: center, radius: 0.02, hardness: 1, color: color)
        PaintPlane.foreshorten(&dab, normal: plane.normal)
        let squash = try XCTUnwrap(dab.squash)
        let frame = TangentFrame(center: center)
        let horizontal = simd_normalize(Vec3(onFloor.x, 0, onFloor.z))
        let side = simd_cross(horizontal, [0, 1, 0])
        let worldRadius = 0.02 // rayon réglé = taille apparente au pied du plan, situé à distance 1
        func angularOffset(_ offset: Vec3) -> Double { simd_length(frame.project(simd_normalize(onFloor + offset))) }
        XCTAssertEqual(angularOffset(side * worldRadius), dab.radius, accuracy: dab.radius * 0.02, "grand axe")
        XCTAssertEqual(angularOffset(horizontal * worldRadius), dab.radius * squash.ratio, accuracy: dab.radius * squash.ratio * 0.05, "petit axe")
        let foot = frame.project(simd_normalize(center + plane.normal * 1e-4))
        XCTAssertEqual(abs(cos(atan2(foot.y, foot.x) - squash.angle)), 1, accuracy: 1e-6, "écrasé vers le pied du plan")
    }

    func testSquashedDabCoverageIsAnEllipse() {
        let center = simd_normalize(Vec3(0.3, 0.4, -1))
        var dab = SphericalDab(center: center, radius: 0.2, hardness: 1, color: [1, 1, 1, 1])
        dab.squash = DabSquash(ratio: 0.25, angle: 0.6)
        let evaluator = DabEvaluator(dab, pixelAngle: 0.0005)
        let frame = evaluator.frame
        func value(along: Double, across: Double) -> Float {
            let c = cos(0.6), s = sin(0.6)
            return evaluator.coverage(at: frame.unproject([along * c - across * s, along * s + across * c]))
        }
        XCTAssertEqual(value(along: 0, across: 0), 1)
        XCTAssertEqual(value(along: 0.049, across: 0), 1, "dans le petit axe")
        XCTAssertEqual(value(along: 0.051, across: 0), 0, "hors du petit axe")
        XCTAssertEqual(value(along: 0, across: 0.199), 1, "dans le grand axe")
        XCTAssertEqual(value(along: 0, across: 0.201), 0, "hors du grand axe")
    }

    func testVeryThinEllipseKeepsItsPaint() throws {
        var dab = SphericalDab(center: [0, 0, -1], radius: 0.1, hardness: 1, color: [1, 1, 1, 1])
        dab.squash = DabSquash(ratio: 0.001, angle: 0)
        let pixel = 0.001
        let resolved = dab.resolved(pixelAngle: pixel)
        let squash = try XCTUnwrap(resolved.squash)
        XCTAssertEqual(squash.ratio * resolved.radius, SphericalDab.minimumRadiusTexels * pixel, accuracy: 1e-12)
        XCTAssertEqual(Double(resolved.color.w) * squash.ratio, 0.001, accuracy: 1e-6, "même quantité de peinture")
    }

    func testPlaneClampStopsAtVanishingLine() {
        let plane = PaintPlane(normal: [0, -1, 0])
        let below = simd_normalize(Vec3(0.3, -0.6, -1))
        XCTAssertEqual(plane.clamped(below), below, "sous l'horizon : inchangé")
        let above = simd_normalize(Vec3(0.3, 0.6, -1))
        let clamped = plane.clamped(above)
        XCTAssertEqual(simd_length(clamped), 1, accuracy: 1e-12)
        XCTAssertEqual(simd_dot(clamped, plane.normal), PaintPlane.minimumCosine, accuracy: 1e-12)
        XCTAssertEqual(atan2(clamped.x, -clamped.z), atan2(above.x, -above.z), accuracy: 1e-9, "même azimut")
    }

    func testPlaneSpacingFollowsTheEllipse() {
        let plane = PaintPlane(normal: [0, -1, 0])
        XCTAssertEqual(plane.spacingScale(at: [0, -1, 0], moving: [1, 0, 0]), 1, accuracy: 1e-9)
        let d = simd_normalize(Vec3(1, -1, 0))
        let c = simd_dot(d, plane.normal)
        // Vers le pied du plan : petit axe ; de côté : grand axe.
        XCTAssertEqual(plane.spacingScale(at: d, moving: plane.normal), c * c, accuracy: 1e-9)
        XCTAssertEqual(plane.spacingScale(at: d, moving: [0, 0, 1]), c, accuracy: 1e-9)
        XCTAssertEqual(plane.spacingScale(at: d, moving: nil), c * c, accuracy: 1e-9)
    }

    func testPlaneGridStaysOnThePlaneSide() {
        let plane = PaintPlane(normal: [0, 1, 0], gridAxis: [1, 0, 0.2])
        XCTAssertEqual(simd_dot(plane.gridAxis, plane.normal), 0, accuracy: 1e-12)
        for line in plane.gridLines() {
            for d in line { XCTAssertGreaterThan(simd_dot(d, plane.normal), 0) }
        }
    }

    // MARK: - Regards

    func testLookInterpolationTakesShortestWay() {
        let a = ViewLook(yaw: 3.0, pitch: 0.2, roll: 0, fov: 1)
        let b = ViewLook(yaw: -3.0, pitch: 0.6, roll: 0, fov: 2)
        let middle = ViewLook.interpolate(a, b, 0.5)
        XCTAssertEqual(middle.yaw, .pi, accuracy: 1e-9, "par l'arrière, pas par tout le tour")
        XCTAssertEqual(middle.pitch, 0.4, accuracy: 1e-12)
        XCTAssertEqual(middle.fov, 1.5, accuracy: 1e-12)
        XCTAssertEqual(ViewLook.interpolate(a, b, 0), a)
    }

    func testCapturedLookLooksAtTheSamePlace() {
        var view = ViewState()
        view.yaw = 0.7
        view.pitch = -0.3
        XCTAssertEqual(view.capturedLook, view.sphereLook)

        var unfolded = ViewState()
        unfolded.mode = .unfolded
        unfolded.morph = 1
        unfolded.unfoldedCenter = [0.8, 0.3]
        let expected = Equirect.direction(u: 0.8, v: 0.3)
        var sphere = ViewState()
        sphere.sphereLook = unfolded.capturedLook
        XCTAssertEqual(simd_distance(sphere.direction(atNDC: .zero, aspect: 1.5)!, expected), 0, accuracy: 1e-9)

        var flat = ViewState()
        flat.showFace(.left)
        sphere.sphereLook = flat.capturedLook
        let left = flat.direction(atNDC: .zero, aspect: 1.5)!
        XCTAssertEqual(simd_distance(sphere.direction(atNDC: .zero, aspect: 1.5)!, left), 0, accuracy: 1e-9)
    }

    func testOppositeFacesLookOppositeWays() {
        for face in CubeFace.allCases {
            var a = ViewState()
            a.showFace(face)
            var b = ViewState()
            b.showFace(face.opposite)
            XCTAssertEqual(face.opposite.opposite, face)
            let sum = a.direction(atNDC: .zero, aspect: 1)! + b.direction(atNDC: .zero, aspect: 1)!
            XCTAssertEqual(simd_length(sum), 0, accuracy: 1e-9, "\(face)")
        }
    }
}
