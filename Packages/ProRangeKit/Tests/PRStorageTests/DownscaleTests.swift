import Foundation
import PRCore
import PRStorage
import simd
import XCTest

final class DownscaleTests: XCTestCase {
    func testHalvedStackKeepsStructureAndAverages() {
        let stack = LayerStack(width: 1024, height: 512)
        let layer = stack.items[0].layer!
        layer.stamp(SphericalDab(center: [0, 0, -1], radius: 0.5, hardness: 1, color: [0.8, 0.2, 0.1, 1]))
        stack.items[0].layer!.opacity = 0.7
        let half = stack.halved()
        XCTAssertEqual(half.width, 512)
        XCTAssertEqual(half.height, 256)
        XCTAssertEqual(half.items.count, stack.items.count)
        XCTAssertEqual(half.items[0].id, stack.items[0].id, "structure conservée")
        let reduced = half.items[0].layer!
        XCTAssertEqual(reduced.opacity, 0.7, accuracy: 1e-6)
        // Centre de la tache : couleur pleine ; moyenne 2 × 2 exacte ailleurs.
        XCTAssertLessThan(simd_reduce_max(simd_abs(reduced.pixel(x: 256, y: 128) - SIMD4<Float>(0.8, 0.2, 0.1, 1))), 2e-3)
        for (x, y) in [(200, 100), (300, 150), (17, 3)] {
            let expected = (layer.pixel(x: 2 * x, y: 2 * y) + layer.pixel(x: 2 * x + 1, y: 2 * y)
                + layer.pixel(x: 2 * x, y: 2 * y + 1) + layer.pixel(x: 2 * x + 1, y: 2 * y + 1)) * 0.25
            XCTAssertLessThan(simd_reduce_max(simd_abs(reduced.pixel(x: x, y: y) - expected)), 2e-3)
        }
        XCTAssertEqual(reduced.pixel(x: 5, y: 250), .zero, "vide reste vide")
    }
}
