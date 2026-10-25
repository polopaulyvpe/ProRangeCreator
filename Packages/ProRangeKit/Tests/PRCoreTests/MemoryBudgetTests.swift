import PRCore
import XCTest

/// Spike phase 1 (b) : chiffres mémoire de référence (section 6 du cahier des charges).
final class MemoryBudgetTests: XCTestCase {
    func testFullLayerSizes() {
        XCTAssertEqual(CanvasResolution.k16.pixelCount, 134_217_728)
        XCTAssertEqual(CanvasResolution.k16.bytesPerFullLayer(.rgba8), 536_870_912)
        XCTAssertEqual(CanvasResolution.k16.bytesPerFullLayer(.rgba16Float), 1_073_741_824)
        XCTAssertEqual(CanvasResolution.k16.bytesPerFullLayer(.rgba32Float), 2_147_483_648)
        XCTAssertEqual(CanvasResolution.k8.bytesPerFullLayer(.rgba16Float), 268_435_456)
    }

    func testGuaranteedLayersForFiveGigabytes() {
        let budget = MemoryBudget(availableBytes: 5 << 30)
        // (5 Gio − 400 Mio) / taille d'un calque − 3 équivalents de travail
        XCTAssertEqual(budget.guaranteedLayers(.k16, .rgba16Float), 1)
        XCTAssertEqual(budget.guaranteedLayers(.k16, .rgba8), 6)
        XCTAssertEqual(budget.guaranteedLayers(.k8, .rgba16Float), 15)
        XCTAssertEqual(budget.guaranteedLayers(.k4, .rgba16Float), 50)
    }

    func testNoBudgetMeansNoLayer() {
        XCTAssertEqual(MemoryBudget(availableBytes: 100 << 20).guaranteedLayers(.k2, .rgba8), 0)
    }
}
