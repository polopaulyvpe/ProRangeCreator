import Metal
import PRCore
import PREngine
import PRStorage
import XCTest

/// Le pinceau GPU contre la référence CPU, puis le cycle complet d'un trait (validation, annulation, historique).
final class BrushEngineTests: XCTestCase {
    private func device() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("pas de GPU Metal sur cette machine") }
        return device
    }

    private func dabs() -> [SphericalDab] {
        [
            SphericalDab(center: Equirect.direction(latitude: 0.1, longitude: 0.3), radius: 0.25, hardness: 0.5, color: [0.9, 0.2, 0.1, 1]),
            SphericalDab(center: Equirect.direction(latitude: 0.2, longitude: 0.4), radius: 0.2, hardness: 1, color: [0.1, 0.3, 0.9, 0.6]),
            SphericalDab(center: [0, 1, 0], radius: 0.3, hardness: 0.7, color: [0.2, 0.8, 0.2, 0.8]),                 // pôle
            SphericalDab(center: Equirect.direction(latitude: -0.3, longitude: .pi), radius: 0.2, hardness: 0.9, color: [2.5, 1.8, 0.4, 1]), // couture, HDR
            SphericalDab(center: Equirect.direction(latitude: 0.15, longitude: 0.35), radius: 0.1, hardness: 0.8, color: [0, 0, 0, 0.7], mode: .erase),
        ]
    }

    private func makeLayerTexture(_ device: any MTLDevice, width: Int, height: Int) throws -> any MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: desc))
        let zeros = [Float16](repeating: 0, count: width * height * 4)
        zeros.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        return texture
    }

    func testGPUBrushMatchesCPUReference() throws {
        let device = try device()
        let engine = try BrushEngine(device: device)
        for space in BlendSpace.allCases {
            let width = 512, height = 256
            let texture = try makeLayerTexture(device, width: width, height: height)
            let commands = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
            let touched = engine.encode(dabs(), space: space, into: texture, commandBuffer: commands)
            commands.commit()
            commands.waitUntilCompleted()
            XCTAssertFalse(touched.isEmpty)

            var gpu = [Float16](repeating: 0, count: width * height * 4)
            gpu.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
            let canvas = EquirectCanvas(width: width, height: height)
            for dab in dabs() { SphericalRasterizer.stamp(dab, on: canvas, space: space) }

            var worst: Float = 0
            var outliers = 0
            for i in 0..<(width * height) {
                let ref = canvas.pixels[i]
                for k in 0..<4 {
                    let diff = abs(Float(gpu[i * 4 + k]) - ref[k])
                    worst = max(worst, diff)
                    if diff > 0.01 { outliers += 1 }
                }
            }
            // Le GPU calcule en float et arrondit en demi-flottants entre deux dabs ; le CPU reste en float 32 bits.
            XCTAssertLessThan(outliers, width * height / 1000, "\(space) : \(outliers) écarts > 0,01 (pire \(worst))")
        }
    }

    func testGPUStrokeCommitCancelAndUndo() throws {
        let device = try device()
        let layer = TiledLayer(name: "t", width: 2048, height: 1024)
        let canvas = LayerCanvas(layer: layer, device: device)
        XCTAssertTrue(canvas.paintsOnGPU)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        func frame() throws {
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            canvas.encodeFrame(into: commands)
            commands.commit()
            commands.waitUntilCompleted()
        }
        try frame() // envoi initial du calque vide

        // Trait annulé : rien ne doit rester, ni dans le calque ni sur le GPU.
        canvas.beginStroke()
        canvas.add(dabs())
        try frame()
        canvas.cancelStroke()
        try frame()
        XCTAssertTrue(layer.storedTiles.isEmpty)
        XCTAssertEqual(canvas.display?.readTile(TileCoord(x: 4, y: 2)), [UInt8](repeating: 0, count: TileSize.pixelCount * 8))

        // Trait validé : le calque CPU reçoit exactement les pixels du GPU, et l'historique peut l'annuler.
        let history = UndoRedoManager()
        canvas.beginStroke()
        canvas.add(Array(dabs().prefix(3)))
        try frame()
        canvas.add(Array(dabs().suffix(2)))
        let deltas = canvas.endStroke()
        XCTAssertFalse(deltas.isEmpty)
        history.record(HistoryEntry(name: "trait", layerID: layer.id, deltas: deltas))
        for coord in layer.storedTiles {
            XCTAssertEqual(layer.tileBytes(coord), canvas.display?.readTile(coord), "\(coord)")
        }

        let undone = try XCTUnwrap(try history.undo(in: [layer]))
        canvas.invalidate(undone.deltas.map(\.coord))
        try frame()
        XCTAssertTrue(layer.storedTiles.isEmpty)
        for delta in undone.deltas {
            XCTAssertEqual(canvas.display?.readTile(delta.coord), [UInt8](repeating: 0, count: TileSize.pixelCount * 8))
        }
    }

    func testCPUFallbackWhenTextureIsReduced() throws {
        let device = try device()
        let layer = TiledLayer(name: "t", width: 2048, height: 1024)
        let canvas = LayerCanvas(layer: layer, device: device, maxDisplayWidth: 1024)
        XCTAssertFalse(canvas.paintsOnGPU)
        canvas.beginStroke()
        canvas.add(dabs())
        XCTAssertFalse(canvas.endStroke().isEmpty)
        XCTAssertFalse(layer.storedTiles.isEmpty)

        canvas.beginStroke()
        canvas.add(dabs())
        let painted = layer.storedTiles.count
        canvas.cancelStroke()
        XCTAssertEqual(layer.storedTiles.count, painted, "annuler un trait CPU le retire sans toucher au précédent")
    }
}
