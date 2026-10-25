import PRCore
import simd
import XCTest

/// Spike phase 1 (a) : le pinceau reste rond sur la sphère à toutes les latitudes, aux pôles et sur la couture.
final class SphericalBrushTests: XCTestCase {
    static let width = 1024
    static let height = 512
    static let white = SIMD4<Float>(1, 1, 1, 1)

    /// Points d'impact testés : équateur, latitudes moyennes et hautes, pôles exacts, couture, couture + haute latitude.
    static let centers: [(name: String, lat: Double, lon: Double)] = [
        ("équateur", 0, 0.3),
        ("45°", 45, -1.0),
        ("75°", 75, 2.0),
        ("88°", 88, 0.7),
        ("pôle nord", 90, 0),
        ("pôle sud", -90, 0),
        ("couture", 10, .pi),
        ("couture 70°S", -70, -.pi + 0.01),
    ]

    /// L'empreinte bornée (EquirectSpan) doit donner exactement le même résultat que le parcours de toute la toile.
    func testBoundedStampMatchesBruteForce() {
        for radiusDeg in [3.0, 12.0, 40.0] {
            for c in Self.centers {
                let dab = makeDab(c.lat, c.lon, radiusDeg: radiusDeg, hardness: 0.6)
                let bounded = EquirectCanvas(width: Self.width, height: Self.height)
                let brute = EquirectCanvas(width: Self.width, height: Self.height)
                SphericalRasterizer.stamp(dab, on: bounded)
                SphericalRasterizer.stamp(dab, on: brute, bruteForce: true)
                XCTAssertEqual(bounded.pixels, brute.pixels, "\(c.name) r=\(radiusDeg)°")
            }
        }
    }

    /// Aire peinte (pondérée par l'angle solide de chaque texel) = aire de la calotte sphérique, à 1,5 % près.
    func testPaintedSolidAngleMatchesCap() {
        for radiusDeg in [6.0, 20.0] {
            let r = radiusDeg * .pi / 180
            let expected = 2 * .pi * (1 - cos(r))
            for c in Self.centers {
                let canvas = EquirectCanvas(width: Self.width, height: Self.height)
                SphericalRasterizer.stamp(makeDab(c.lat, c.lon, radiusDeg: radiusDeg, hardness: 1), on: canvas)
                var area = 0.0
                for y in 0..<canvas.height {
                    let omega = canvas.texelSolidAngle(row: y)
                    for x in 0..<canvas.width { area += Double(canvas[x, y].w) * omega }
                }
                XCTAssertEqual(area / expected, 1, accuracy: 0.015, "\(c.name) r=\(radiusDeg)°")
            }
        }
    }

    /// Rondeur mesurée : dans chaque secteur d'azimut autour du centre, le texel peint le plus éloigné est au rayon voulu.
    func testFootprintIsRoundOnSphere() {
        let radiusDeg = 10.0
        let r = radiusDeg * .pi / 180
        for c in Self.centers {
            let canvas = EquirectCanvas(width: Self.width, height: Self.height)
            let dab = makeDab(c.lat, c.lon, radiusDeg: radiusDeg, hardness: 1)
            SphericalRasterizer.stamp(dab, on: canvas)
            let frame = TangentFrame(center: dab.center)
            let sectors = 16
            var reach = [Double](repeating: 0, count: sectors)
            for y in 0..<canvas.height {
                for x in 0..<canvas.width where canvas[x, y].w >= 0.5 {
                    let p = frame.project(canvas.direction(x: x, y: y))
                    let turn: Double = (atan2(p.x, p.y) + .pi) / (2 * .pi)
                    let sector = Int(turn * Double(sectors)) % sectors
                    reach[sector] = max(reach[sector], simd_length(p))
                }
            }
            let tolerance = canvas.pixelAngle
            for (i, value) in reach.enumerated() {
                XCTAssertEqual(value, r, accuracy: tolerance, "\(c.name) secteur \(i)")
            }
        }
    }

    func testHardnessFalloff() {
        let px = 0.001
        XCTAssertEqual(SphericalRasterizer.coverage(distance: 0, radius: 1, hardness: 0, pixelSize: px), 1, accuracy: 1e-9)
        XCTAssertEqual(SphericalRasterizer.coverage(distance: 0.5, radius: 1, hardness: 0, pixelSize: px), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SphericalRasterizer.coverage(distance: 1.01, radius: 1, hardness: 1, pixelSize: px), 0)
        XCTAssertEqual(SphericalRasterizer.coverage(distance: 1, radius: 1, hardness: 1, pixelSize: px), 0.5, accuracy: 1e-9)
    }

    private func makeDab(_ latDeg: Double, _ lon: Double, radiusDeg: Double, hardness: Double) -> SphericalDab {
        SphericalDab(center: Equirect.direction(latitude: latDeg * .pi / 180, longitude: lon),
                     radius: radiusDeg * .pi / 180, hardness: hardness, color: [0.2, 0.4, 0.9, 1])
    }
}
