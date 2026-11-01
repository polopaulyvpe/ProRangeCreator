import PRCore
import simd
import XCTest

/// Tracé lisse : courbe de Catmull-Rom centripète, dabs régulièrement espacés, pression interpolée dab par dab.
final class SplineStrokeTests: XCTestCase {
    private func run(_ points: [StrokeSample], spacing: Double, onSphere: Bool) -> [StrokeSample] {
        var sampler = SplineStrokeSampler(onSphere: onSphere)
        var out = sampler.begin(points[0])
        for p in points.dropFirst() { out += sampler.add(p) { _ in spacing } }
        out += sampler.finish { _ in spacing }
        return out
    }

    func testStraightLineIsEvenlySpacedWithInterpolatedPressure() {
        let points = (0...10).map { i in StrokeSample(point: [Double(i) * 10, 0, 0], pressure: Double(i) / 10) }
        let dabs = run(points, spacing: 2, onSphere: false)
        XCTAssertTrue((50...51).contains(dabs.count), "100 pixels à 2 pixels d'écart, plus le premier : \(dabs.count)")
        for (a, b) in zip(dabs, dabs.dropFirst()) {
            XCTAssertEqual(simd_distance(a.point, b.point), 2, accuracy: 1e-6)
            XCTAssertEqual(a.point.y, 0, accuracy: 1e-9)
        }
        // Pression proportionnelle à la position : plus de marches d'un point saisi à l'autre.
        for d in dabs { XCTAssertEqual(d.pressure, d.point.x / 100, accuracy: 1e-6) }
    }

    func testCurveIsRoundBetweenSparseSamples() {
        // Cercle de rayon 100 saisi avec seulement 12 points : les segments droits s'en écartent de 3,4 pixels,
        // la courbe passe beaucoup plus près.
        let points = (0...12).map { i -> StrokeSample in
            let a = Double(i) / 12 * 2 * .pi
            return StrokeSample(point: [100 * cos(a), 100 * sin(a), 0], pressure: 1)
        }
        let dabs = run(points, spacing: 1, onSphere: false)
        let inner = dabs.dropFirst(60).dropLast(60)
        let worst = inner.map { abs(simd_length(SIMD2($0.point.x, $0.point.y)) - 100) }.max()!
        XCTAssertLessThan(worst, 0.6, "écart au cercle \(worst)")
        let chordSag = 100 * (1 - cos(Double.pi / 12))
        XCTAssertGreaterThan(chordSag, 3)
    }

    func testOnSphereStaysOnSphere() {
        let points = (0...8).map { i in
            StrokeSample(point: Equirect.direction(latitude: 0.2 * sin(Double(i)), longitude: Double(i) * 0.05), pressure: 0.5)
        }
        let dabs = run(points, spacing: 0.005, onSphere: true)
        XCTAssertGreaterThan(dabs.count, 50)
        for d in dabs { XCTAssertEqual(simd_length(d.point), 1, accuracy: 1e-9) }
        for (a, b) in zip(dabs, dabs.dropFirst()) { XCTAssertEqual(Sphere.angle(a.point, b.point), 0.005, accuracy: 1e-4) }
    }

    func testSpacingFollowsLocalPressure() {
        // Espacement proportionnel à la pression : dense au début (pression faible), lâche à la fin.
        let points = [StrokeSample(point: [0, 0, 0], pressure: 0.1), StrokeSample(point: [100, 0, 0], pressure: 1)]
        var sampler = SplineStrokeSampler(onSphere: false)
        var dabs = sampler.begin(points[0])
        dabs += sampler.add(points[1]) { p in 10 * p }
        dabs += sampler.finish { p in 10 * p }
        let first = simd_distance(dabs[0].point, dabs[1].point)
        let last = simd_distance(dabs[dabs.count - 2].point, dabs[dabs.count - 1].point)
        XCTAssertLessThan(first, 2)
        XCTAssertGreaterThan(last, 8)
    }

    func testSubTexelDabsAreEnlargedWithSameInk() {
        let tiny = SphericalDab(center: [0, 0, -1], radius: 0.35, hardness: 1, color: [1, 1, 1, 1])
        let resolved = tiny.resolved(pixelAngle: 1)
        XCTAssertEqual(resolved.radius, SphericalDab.minimumRadiusTexels, accuracy: 1e-12)
        XCTAssertEqual(Double(resolved.color.w), 0.25, accuracy: 1e-6, "aire conservée : (0,35 / 0,7)²")
        let big = SphericalDab(center: [0, 0, -1], radius: 3, hardness: 1, color: [1, 1, 1, 1])
        XCTAssertEqual(big.resolved(pixelAngle: 1).radius, 3)
    }

    func testEndTaper() {
        var brush = BrushSettings(radiusDegrees: 1)
        XCTAssertEqual(brush.endTaper(remaining: 0).size, 1, "sans effilement")
        brush.taperEndLength = 2
        brush.taperSize = 0.8
        brush.taperOpacity = 0.5
        let length = 2 * 2 * Double.pi / 180
        XCTAssertEqual(brush.endTaper(remaining: 0).size, 0.2, accuracy: 1e-12)
        XCTAssertEqual(brush.endTaper(remaining: 0).opacity, 0.5, accuracy: 1e-12)
        XCTAssertEqual(brush.endTaper(remaining: length / 2).size, 0.6, accuracy: 1e-12)
        XCTAssertEqual(brush.endTaper(remaining: length * 3).size, 1)
    }
}
