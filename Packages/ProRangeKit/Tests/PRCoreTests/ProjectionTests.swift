import PRCore
import simd
import XCTest

final class ProjectionTests: XCTestCase {
    func testKnownDirections() {
        assertClose(Equirect.direction(u: 0.5, v: 0.5), [0, 0, -1])
        assertClose(Equirect.direction(u: 0.75, v: 0.5), [1, 0, 0])
        assertClose(Equirect.direction(u: 0.25, v: 0.5), [-1, 0, 0])
        assertClose(Equirect.direction(u: 0.3, v: 0), [0, 1, 0])
        assertClose(Equirect.direction(u: 0.8, v: 1), [0, -1, 0])
    }

    /// Aller-retour pixel → direction → pixel sur toute une grille, pôles, couture et coins compris.
    func testPixelRoundTrip() {
        let w = 512, h = 256
        let xs = [0, 1, w / 4, w / 2 - 1, w / 2, w - 2, w - 1]
        let ys = [0, 1, h / 2 - 1, h / 2, h - 2, h - 1]
        for y in ys {
            for x in xs {
                let d = Equirect.direction(x: x, y: y, width: w, height: h)
                XCTAssertEqual(simd_length(d), 1, accuracy: 1e-12)
                let p = Equirect.pixel(from: d, width: w, height: h)
                XCTAssertEqual(p.x, Double(x) + 0.5, accuracy: 1e-9, "x=\(x) y=\(y)")
                XCTAssertEqual(p.y, Double(y) + 0.5, accuracy: 1e-9, "x=\(x) y=\(y)")
            }
        }
    }

    func testLatitudeLongitudeRoundTrip() {
        for lat in stride(from: -89.0, through: 89.0, by: 22.25) {
            for lon in stride(from: -179.0, through: 179.0, by: 44.75) {
                let d = Equirect.direction(latitude: lat * .pi / 180, longitude: lon * .pi / 180)
                XCTAssertEqual(Equirect.latitude(of: d) * 180 / .pi, lat, accuracy: 1e-9)
                XCTAssertEqual(Equirect.longitude(of: d) * 180 / .pi, lon, accuracy: 1e-9)
            }
        }
    }

    func testTangentFrameIsEquidistant() {
        for lat in [0.0, 45, 80, 90, -90] {
            let c = Equirect.direction(latitude: lat * .pi / 180, longitude: 0.4)
            let frame = TangentFrame(center: c)
            XCTAssertEqual(simd_length(frame.project(c)), 0, accuracy: 1e-12)
            for azimuth in stride(from: 0.0, to: 2 * .pi, by: .pi / 7) {
                let p = SIMD2<Double>(sin(azimuth), cos(azimuth)) * 0.3
                let d = frame.unproject(p)
                XCTAssertEqual(Sphere.angle(c, d), 0.3, accuracy: 1e-12, "la distance au centre doit être l'angle")
                let back = frame.project(d)
                XCTAssertEqual(back.x, p.x, accuracy: 1e-12)
                XCTAssertEqual(back.y, p.y, accuracy: 1e-12)
            }
        }
    }

    func testTangentFrameNorthPointsToZenith() {
        let c = Equirect.direction(latitude: 0.3, longitude: 1.2)
        let frame = TangentFrame(center: c)
        let p = frame.project(Equirect.direction(latitude: 0.5, longitude: 1.2))
        XCTAssertEqual(p.x, 0, accuracy: 1e-12)
        XCTAssertEqual(p.y, 0.2, accuracy: 1e-12)
    }

    func testStrokeSamplerKeepsConstantAngularSpacing() {
        var sampler = SphericalStrokeSampler()
        let spacing = 0.01
        var dabs = sampler.begin(at: Equirect.direction(latitude: 0.2, longitude: 3.0))
        // Trait qui traverse la couture puis monte vers le pôle, en événements de tailles irrégulières.
        let points: [(Double, Double)] = [(0.21, 3.05), (0.25, 3.12), (0.3, -3.1), (0.6, -3.0), (1.2, -2.9), (1.5, -2.0)]
        for (lat, lon) in points {
            dabs += sampler.add(Equirect.direction(latitude: lat, longitude: lon), spacing: spacing)
        }
        XCTAssertGreaterThan(dabs.count, 100)
        // Mesuré en ligne droite sur la sphère, l'écart entre dabs raccourcit un peu là où le trait tourne entre deux événements.
        for i in 1..<dabs.count {
            let angle = Sphere.angle(dabs[i - 1], dabs[i])
            XCTAssertLessThanOrEqual(angle, spacing + 1e-9, "dab \(i)")
            XCTAssertGreaterThan(angle, 0.8 * spacing, "dab \(i)")
        }
    }

    func testStrokeSamplerIsExactAlongOneGreatCircle() {
        var sampler = SphericalStrokeSampler()
        let a = Equirect.direction(latitude: -0.4, longitude: 2.9)
        let b = Equirect.direction(latitude: 0.7, longitude: -2.8)
        var dabs = sampler.begin(at: a)
        dabs += sampler.add(b, spacing: 0.02)
        XCTAssertEqual(dabs.count, Int(Sphere.angle(a, b) / 0.02) + 1)
        for i in 1..<dabs.count {
            XCTAssertEqual(Sphere.angle(dabs[i - 1], dabs[i]), 0.02, accuracy: 1e-9)
        }
    }

    func testColorTransferRoundTrip() {
        for c in stride(from: Float(0), through: 1, by: 0.05) {
            XCTAssertEqual(ColorTransfer.toEncoded(ColorTransfer.toLinear(c)), c, accuracy: 1e-5)
        }
        XCTAssertEqual(ColorTransfer.encode8(1), 255)
        XCTAssertEqual(ColorTransfer.encode8(4), 255)
        XCTAssertEqual(ColorTransfer.encode8(0), 0)
    }

    private func assertClose(_ a: Vec3, _ b: Vec3, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_length(a - b), 1e-12, "\(a) ≠ \(b)", file: file, line: line)
    }
}
