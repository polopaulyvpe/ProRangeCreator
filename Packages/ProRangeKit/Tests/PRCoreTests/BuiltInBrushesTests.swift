import PRCore
import simd
import XCTest

final class BuiltInBrushesTests: XCTestCase {
    func testCatalogIsCompleteAndShapesAreUsable() {
        let all = BuiltInBrushes.all
        XCTAssertGreaterThanOrEqual(all.count, 15)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "identifiants uniques")
        for category in BuiltInBrushes.categories {
            XCTAssertFalse(all.filter { $0.category == category }.isEmpty, "catégorie \(category) vide")
        }
        for brush in all {
            for texture in [brush.settings.shape, brush.settings.grain].compactMap({ $0 }) {
                let mean = texture.values.reduce(0, +) / Float(texture.values.count)
                XCTAssertGreaterThan(mean, 0.001, "\(brush.name) / \(texture.name) : presque vide")
                XCTAssertLessThan(mean, 0.95, "\(brush.name) / \(texture.name) : presque plein")
                XCTAssertTrue(texture.values.allSatisfy { $0 >= 0 && $0 <= 1 })
            }
        }
    }

    func testStampsPaintOnTheSphere() throws {
        let center = Equirect.direction(latitude: 0.2, longitude: 0)
        let frame = TangentFrame(center: center)
        let sun = try XCTUnwrap(BuiltInBrushes.all.first { $0.name == "Soleil" })
        let dab = sun.settings.dab(at: center, pressure: 1, color: .one, mode: .paint)
        let evaluator = DabEvaluator(dab, pixelAngle: 0.001)
        XCTAssertGreaterThan(evaluator.coverage(at: center), 0.9, "cœur du soleil")
        XCTAssertLessThan(evaluator.coverage(at: frame.unproject([dab.radius * 0.9, 0])), 0.2, "halo qui s'éteint")

        // Silhouette de collines : pleine en bas du tampon, vide en haut.
        let hills = try XCTUnwrap(BuiltInBrushes.all.first { $0.name == "Collines" })
        let h = hills.settings.dab(at: center, pressure: 1, color: .one, mode: .paint)
        let e = DabEvaluator(h, pixelAngle: 0.001)
        XCTAssertGreaterThan(e.coverage(at: frame.unproject([0, -h.radius * 0.9])), 0.9)
        XCTAssertLessThan(e.coverage(at: frame.unproject([0, h.radius * 0.9])), 0.1)
    }
}
