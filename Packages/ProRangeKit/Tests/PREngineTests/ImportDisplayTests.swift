import Metal
import PRCore
import PREngine
import PRStorage
import XCTest

/// Un calque rempli d'un coup (comme un import d'image, avec de la transparence partielle) doit s'afficher à l'identique,
/// qu'il soit actif (texture du calque) ou dessous / dessus (caches composés sur le GPU).
final class ImportDisplayTests: XCTestCase {
    private func halves(_ bytes: [UInt8]) -> [Float] {
        bytes.withUnsafeBytes { raw in raw.bindMemory(to: Float16.self).map { Float($0) } }
    }

    private func worst(_ texture: DisplayTexture, _ expected: (TileCoord) -> [SIMD4<Float>], tiles: [TileCoord]) -> Float {
        var worst: Float = 0
        for coord in tiles {
            let gpu = halves(texture.readTile(coord))
            let cpu = expected(coord)
            for i in cpu.indices {
                for k in 0..<4 { worst = max(worst, abs(gpu[i * 4 + k] - cpu[i][k]) / max(1, abs(cpu[i][k]))) }
            }
        }
        return worst
    }

    func testImportedLayerDisplaysIdentically() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("pas de GPU Metal sur cette machine")
        }
        let stack = LayerStack(width: 1024, height: 512)
        let base = stack.items[0].layer!
        base.stamp(SphericalDab(center: [0, 0, -1], radius: 0.8, hardness: 0.5, color: [0.2, 0.6, 0.3, 1]))
        let imported = try XCTUnwrap(stack.addLayer(above: stack.items[0].id, name: "Import")?.layer)
        // « Image importée » : dégradé avec un alpha qui va de 0 à 1, posée sur toutes les tuiles.
        imported.beginOperation()
        for ty in 0..<imported.tilesDown {
            for tx in 0..<imported.tilesAcross {
                let coord = TileCoord(x: tx, y: ty)
                let pixels = (0..<TileSize.pixelCount).map { i -> SIMD4<Float> in
                    let x = Float(tx * TileSize.side + i % TileSize.side) / 1024
                    let y = Float(ty * TileSize.side + i / TileSize.side) / 512
                    let a = min(1, max(0, x * 1.4 - 0.2))
                    return SIMD4<Float>(0.9 * a, 0.4 * y * a, 0.1 * a, a)
                }
                imported.replaceTile(coord, withPixels: pixels)
            }
        }
        _ = imported.endOperation()
        let tiles = (0..<2).flatMap { ty in (0..<4).map { TileCoord(x: $0, y: ty) } }

        let canvas = StackCanvas(stack: stack, device: device)
        func frame() {
            let commands = queue.makeCommandBuffer()!
            canvas.encodeFrame(into: commands)
            commands.commit()
            commands.waitUntilCompleted()
        }
        // Calque importé actif : la texture active reprend ses octets, le dessous est le calque de base sur le papier.
        canvas.activeID = stack.items.last!.id
        canvas.setNeedsRefresh()
        frame()
        let active = try XCTUnwrap(canvas.active)
        for coord in tiles { XCTAssertEqual(active.readTile(coord), imported.tileBytes(coord), "texture active \(coord)") }
        let below = try XCTUnwrap(canvas.below)
        XCTAssertLessThan(worst(below, { LayerCompositor.compositeTile($0, stack: stack, rootRange: 0..<1, paper: [1, 1, 1], space: .perceptual) },
                                tiles: tiles), 3e-3, "dessous composé sur le GPU")

        // Calque de base actif : l'import passe au-dessus, composé sur le GPU.
        canvas.activeID = stack.items[0].id
        canvas.setNeedsRefresh()
        frame()
        let above = try XCTUnwrap(canvas.above)
        XCTAssertLessThan(worst(above, { LayerCompositor.compositeTile($0, stack: stack, rootRange: 1..<2, paper: nil, space: .perceptual) },
                                tiles: tiles), 3e-3, "dessus composé sur le GPU")
    }
}
