import Foundation
import PRCore
import PRStorage
import simd
import XCTest

final class FilterReferenceTests: XCTestCase {
    func testAdjustmentTouchesOnlyPaintedTiles() {
        let layer = TiledLayer(name: "t", width: 1024, height: 512)
        layer.stamp(SphericalDab(center: [0, 0, -1], radius: 0.1, hardness: 1, color: [0.8, 0.2, 0.2, 1]))
        let stored = Set(layer.storedTiles)
        layer.beginOperation()
        let touched = layer.applyAdjustment(.hueSaturation(hue: 0, saturation: -1, brightness: 0))
        XCTAssertEqual(touched, stored)
        XCTAssertFalse(layer.endOperation().isEmpty)
        let p = layer.pixel(x: 512, y: 256)
        XCTAssertEqual(p.x, p.y, accuracy: 2e-3, "désaturé")
    }

    /// Le flou séparable (rayon horizontal en 1/cos(latitude)) approche le vrai flou gaussien sphérique.
    func testSeparableBlurApproximatesExactSphericalBlur() {
        let width = 96, height = 48
        let layer = TiledLayer(name: "t", width: width, height: height)
        layer.stamp(SphericalDab(center: Equirect.direction(latitude: 0.2, longitude: 0.5), radius: 0.3, hardness: 1, color: [1, 0.5, 0.1, 1]))
        layer.stamp(SphericalDab(center: Equirect.direction(latitude: 1.1, longitude: -2), radius: 0.3, hardness: 1, color: [0.1, 0.3, 1, 1]))
        let pixels = layer.allPixels()
        let sigma = 0.12
        let separable = FilterReference.separableBlur(pixels, width: width, height: height, sigma: sigma)
        let exact = FilterReference.exactSphericalBlur(pixels, width: width, height: height, sigma: sigma)
        var worst: Float = 0
        var sumError: Float = 0
        // On compare hors des rangées très proches des pôles, où l'approximation séparable atteint ses limites.
        for y in 4..<(height - 4) {
            for x in 0..<width {
                let e = simd_reduce_max(simd_abs(separable[y * width + x] - exact[y * width + x]))
                worst = max(worst, e)
                sumError += e
            }
        }
        XCTAssertLessThan(sumError / Float(width * (height - 8)), 0.02, "erreur moyenne")
        XCTAssertLessThan(worst, 0.15, "pire écart")
    }

    func testBlurPreservesUniformImages() {
        let width = 64, height = 32
        let uniform = [SIMD4<Float>](repeating: [0.3, 0.6, 0.9, 1], count: width * height)
        let blurred = FilterReference.separableBlur(uniform, width: width, height: height, sigma: 0.3)
        for p in blurred { XCTAssertLessThan(simd_reduce_max(simd_abs(p - uniform[0])), 1e-5) }
    }

    func testNoiseKeepsTransparencyAndVaries() {
        let width = 64, height = 32
        var pixels = [SIMD4<Float>](repeating: [0.2, 0.2, 0.2, 1], count: width * height)
        pixels[0] = .zero
        let noisy = FilterReference.noise(pixels, width: width, height: height, amount: 0.2,
                                          cell: .pi / Double(height), seed: 1, monochrome: true)
        XCTAssertEqual(noisy[0], .zero, "transparent intact")
        XCTAssertGreaterThan(Set(noisy.map(\.x)).count, 10, "grain présent")
        XCTAssertEqual(noisy[100].x, noisy[100].y, accuracy: 1e-6, "monochrome")
    }
}
