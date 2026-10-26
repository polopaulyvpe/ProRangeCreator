import PRCore
import simd
import XCTest

final class AdjustmentTests: XCTestCase {
    private let color = SIMD4<Float>(0.2, 0.05, 0.4, 0.8) // linéaire prémultiplié

    private func close(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ tolerance: Float = 1e-4) -> Bool {
        simd_reduce_max(simd_abs(a - b)) <= tolerance
    }

    func testToneCurve() {
        let identity = ToneCurve.identity
        for x in stride(from: 0.0, through: 1.0, by: 0.1) { XCTAssertEqual(identity.evaluate(x), x, accuracy: 1e-9) }
        let s = ToneCurve(points: [[0, 0], [0.25, 0.15], [0.5, 0.5], [0.75, 0.85], [1, 1]])
        var previous = -1.0
        for x in stride(from: 0.0, through: 1.0, by: 0.01) {
            let y = s.evaluate(x)
            XCTAssertGreaterThanOrEqual(y, previous - 1e-12, "monotone")
            previous = y
        }
        XCTAssertEqual(s.evaluate(0.25), 0.15, accuracy: 1e-9, "passe par ses points")
        let hdr = ToneCurve(points: [[0, 0], [2, 3], [4, 4]], maxInput: 4)
        XCTAssertEqual(hdr.evaluate(2), 3, accuracy: 1e-9)
        XCTAssertGreaterThan(hdr.evaluate(6), hdr.evaluate(4), "prolongée au-delà du domaine")
        XCTAssertEqual(s.table(count: 11)[5], 0.5, accuracy: 1e-6)
    }

    func testPointAdjustments() {
        XCTAssertTrue(close(Adjustment.hueSaturation(hue: 0, saturation: 0, brightness: 0).apply(color), color))
        XCTAssertTrue(close(Adjustment.curves(.identity).apply(color), color))
        XCTAssertEqual(Adjustment.hueSaturation(hue: 0.3, saturation: 0, brightness: 0).apply(.zero), .zero, "transparent intact")

        let gray = Adjustment.hueSaturation(hue: 0, saturation: -1, brightness: 0).apply(color)
        XCTAssertEqual(gray.x, gray.y, accuracy: 1e-5, "désaturé : gris")
        XCTAssertEqual(gray.w, color.w, "alpha conservé")

        let inverted = Adjustment.curves(ToneCurve(points: [[0, 1], [1, 0]])).apply([0, 0, 0, 1])
        XCTAssertEqual(inverted.x, 1, accuracy: 1e-5)

        let mapped = Adjustment.gradientMap(dark: [0, 0, 0], light: [1, 0, 0]).apply([1, 1, 1, 1])
        XCTAssertEqual(mapped.x, 1, accuracy: 1e-4)
        XCTAssertEqual(mapped.y, 0, accuracy: 1e-4)

        let red = SIMD4<Float>(0.8, 0.01, 0.01, 1)
        let recolored = Adjustment.recolor(from: 0, to: 1.0 / 3, tolerance: 0.1).apply(red)
        XCTAssertGreaterThan(recolored.y, recolored.x, "rouge devenu vert")
        let blue = SIMD4<Float>(0.01, 0.01, 0.8, 1)
        XCTAssertTrue(close(Adjustment.recolor(from: 0, to: 1.0 / 3, tolerance: 0.1).apply(blue), blue, 1e-3), "hors tolérance : intact")

        // HDR : la teinte tourne sans écraser l'intensité au-delà de 1.
        let bright = SIMD4<Float>(4, 1, 0.2, 1)
        let turned = Adjustment.hueSaturation(hue: 0.5, saturation: 0, brightness: 0).apply(bright)
        XCTAssertGreaterThan(simd_reduce_max(SIMD3<Float>(turned.x, turned.y, turned.z)), 2)

        let balanced = Adjustment.colorBalance(shadows: .zero, midtones: [1, 0, 0], highlights: .zero).apply([0.2, 0.2, 0.2, 1])
        XCTAssertGreaterThan(balanced.x, balanced.y, "tons moyens poussés vers le rouge")
    }

    func testSphericalNoise() {
        let cell = 0.01
        let d = Equirect.direction(latitude: 0.3, longitude: 1.2)
        XCTAssertEqual(SphericalNoise.value(d, cell: cell, seed: 3), SphericalNoise.value(d, cell: cell, seed: 3), "déterministe")
        XCTAssertNotEqual(SphericalNoise.value(d, cell: cell, seed: 3), SphericalNoise.value(d, cell: cell, seed: 4))
        // Continu à travers la couture : deux directions voisines de part et d'autre tombent dans la même cellule.
        let west = Equirect.direction(latitude: 0.1, longitude: .pi - 1e-6)
        let east = Equirect.direction(latitude: 0.1, longitude: -.pi + 1e-6)
        XCTAssertEqual(SphericalNoise.value(west, cell: cell, seed: 1), SphericalNoise.value(east, cell: cell, seed: 1))
        var sum: Float = 0
        let n = 2000
        for i in 0..<n {
            sum += SphericalNoise.value(Equirect.direction(latitude: Double(i % 40) * 0.07 - 1.4, longitude: Double(i) * 0.31),
                                        cell: cell, seed: 9)
        }
        XCTAssertEqual(sum / Float(n), 0.5, accuracy: 0.03, "uniforme")
    }
}
