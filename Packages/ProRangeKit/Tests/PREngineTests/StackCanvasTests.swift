import Metal
import PRCore
import PREngine
import PRStorage
import simd
import XCTest

/// La pile côté GPU : composition du shader contre le compositeur CPU (tous les modes), cycle d'un trait, chemin CPU.
final class StackCanvasTests: XCTestCase {
    private let width = 512
    private let height = 256

    private func device() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("pas de GPU Metal sur cette machine") }
        return device
    }

    private func frame(_ canvas: StackCanvas, _ queue: any MTLCommandQueue) throws {
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        canvas.encodeFrame(into: commands)
        commands.commit()
        commands.waitUntilCompleted()
    }

    /// Dessous peint, calque actif avec le mode testé, dessus en Normal à demi opaque.
    private func makeStack() -> (LayerStack, active: UUID) {
        let stack = LayerStack(width: width, height: height)
        let base = stack.items[0].layer!
        base.stamp(SphericalDab(center: [0, 0, -1], radius: 0.9, hardness: 0.3, color: [0.2, 0.5, 0.8, 1]))
        base.stamp(SphericalDab(center: Equirect.direction(latitude: 0.3, longitude: 2), radius: 0.6, hardness: 0.6, color: [0.9, 0.7, 0.1, 0.9]))
        let active = stack.addLayer()!
        active.layer!.stamp(SphericalDab(center: Equirect.direction(latitude: -0.1, longitude: 0.4), radius: 0.8, hardness: 0.4, color: [0.8, 0.2, 0.4, 0.85]))
        active.layer!.stamp(SphericalDab(center: [0, 1, 0], radius: 0.5, hardness: 0.8, color: [0.3, 0.9, 0.6, 1]))
        let top = stack.addLayer()!
        top.layer!.stamp(SphericalDab(center: Equirect.direction(latitude: 0.2, longitude: -0.5), radius: 0.4, hardness: 0.9, color: [0.1, 0.1, 0.1, 0.5]))
        return (stack, active.id)
    }

    private func render(_ canvas: StackCanvas, renderer: PanoramaRenderer) throws -> [Float16] {
        var view = ViewState()
        view.mode = .unfolded
        view.morph = 1
        var uniforms = ViewUniforms(view.parameters(aspect: 2), viewportHeight: height, textureHeight: height)
        canvas.configure(&uniforms)
        let layers = try XCTUnwrap(canvas.panoramaLayers())
        return try renderer.renderOffscreen(layers: layers, width: width, height: height, uniforms: uniforms, filtering: .nearest)
    }

    /// Composite CPU attendu, écrêté à [0, 1] comme l'affichage par défaut.
    private func reference(_ stack: LayerStack, space: BlendSpace) -> [SIMD4<Float>] {
        var out = [SIMD4<Float>](repeating: .zero, count: width * height)
        let side = TileSize.side
        for ty in 0..<(height / side) {
            for tx in 0..<(width / side) {
                let tile = LayerCompositor.compositeTile(TileCoord(x: tx, y: ty), stack: stack, paper: [1, 1, 1], space: space)
                for y in 0..<side {
                    for x in 0..<side { out[(ty * side + y) * width + tx * side + x] = simd_clamp(tile[y * side + x], .zero, .one) }
                }
            }
        }
        return out
    }

    private func mismatches(_ gpu: [Float16], _ cpu: [SIMD4<Float>]) -> (count: Int, worst: Float) {
        var count = 0
        var worst: Float = 0
        for i in cpu.indices {
            for k in 0..<3 {
                let diff = abs(Float(gpu[i * 4 + k]) - cpu[i][k])
                worst = max(worst, diff)
                if diff > 0.01 { count += 1 }
            }
        }
        return (count, worst)
    }

    func testShaderCompositeMatchesCPUForEveryMode() throws {
        let device = try device()
        let renderer = try PanoramaRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let (stack, activeID) = makeStack()
        let canvas = StackCanvas(stack: stack, device: device)
        canvas.activeID = activeID
        for space in BlendSpace.allCases {
            canvas.blendSpace = space
            for mode in BlendMode.allCases {
                stack.update(activeID) { $0.blendMode = mode; $0.opacity = 0.9 }
                canvas.setNeedsRefresh()
                try frame(canvas, queue)
                XCTAssertTrue(canvas.usesFastPath, "chemin GPU attendu")
                let (count, worst) = mismatches(try render(canvas, renderer: renderer), reference(stack, space: space))
                // Seuils et discontinuités (Mélange maximal, Couleur plus foncée…) peuvent basculer sur quelques pixels.
                XCTAssertLessThan(count, width * height * 3 / 200, "\(space) \(mode) : \(count) écarts > 0,01 (pire \(worst))")
            }
        }
    }

    func testCPUPathWhenActiveHasMaskOrModeAbove() throws {
        let device = try device()
        let renderer = try PanoramaRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let (stack, activeID) = makeStack()
        let canvas = StackCanvas(stack: stack, device: device)
        canvas.activeID = activeID

        stack.items.last.map { top in stack.update(top.id) { $0.blendMode = .multiply } }
        canvas.setNeedsRefresh()
        try frame(canvas, queue)
        XCTAssertFalse(canvas.usesFastPath, "un Produit au-dessus impose le chemin CPU")
        XCTAssertLessThan(mismatches(try render(canvas, renderer: renderer), reference(stack, space: .perceptual)).count, width * height * 3 / 200)

        stack.items.last.map { top in stack.update(top.id) { $0.blendMode = .normal } }
        stack.addMask(activeID)
        stack.item(activeID)!.mask!.stamp(SphericalDab(center: [0, 0, -1], radius: 0.5, hardness: 1, color: [0, 0, 0, 1]))
        canvas.setNeedsRefresh()
        try frame(canvas, queue)
        XCTAssertFalse(canvas.usesFastPath, "un masque impose le chemin CPU")
        XCTAssertLessThan(mismatches(try render(canvas, renderer: renderer), reference(stack, space: .perceptual)).count, width * height * 3 / 200)

        // Peinture du masque (chemin CPU) : le trait modifie le masque et s'annule proprement.
        canvas.paintingMask = true
        canvas.beginStroke()
        canvas.add([SphericalDab(center: [0, 0, -1], radius: 0.2, hardness: 1, color: [1, 1, 1, 1])])
        let result = try XCTUnwrap(canvas.endStroke())
        XCTAssertEqual(result.layerID, stack.item(activeID)!.mask!.id)
        XCTAssertFalse(result.deltas.isEmpty)
    }

    func testGPUStrokeCommitCancelAndUndo() throws {
        let device = try device()
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let stack = LayerStack(width: 2048, height: 1024)
        let canvas = StackCanvas(stack: stack, device: device)
        let layer = stack.items[0].layer!
        try frame(canvas, queue)
        XCTAssertTrue(canvas.usesFastPath)
        let dabs = [
            SphericalDab(center: Equirect.direction(latitude: 0.1, longitude: 0.3), radius: 0.25, hardness: 0.5, color: [0.9, 0.2, 0.1, 1]),
            SphericalDab(center: [0, 1, 0], radius: 0.3, hardness: 0.7, color: [0.2, 0.8, 0.2, 0.8]),
            SphericalDab(center: Equirect.direction(latitude: -0.3, longitude: .pi), radius: 0.2, hardness: 0.9, color: [2.5, 1.8, 0.4, 1]),
        ]
        let zeros = [UInt8](repeating: 0, count: TileSize.pixelCount * 8)

        canvas.beginStroke()
        canvas.add(dabs)
        try frame(canvas, queue)
        canvas.cancelStroke()
        try frame(canvas, queue)
        XCTAssertTrue(layer.storedTiles.isEmpty)
        XCTAssertEqual(canvas.active?.readTile(TileCoord(x: 4, y: 1)), zeros)

        let history = UndoRedoManager()
        canvas.beginStroke()
        canvas.add(Array(dabs.prefix(2)))
        try frame(canvas, queue)
        canvas.add(Array(dabs.suffix(1)))
        let result = try XCTUnwrap(canvas.endStroke())
        XCTAssertEqual(result.layerID, layer.id)
        history.record(HistoryEntry(name: "trait", layerID: result.layerID, deltas: result.deltas))
        for coord in layer.storedTiles {
            XCTAssertEqual(layer.tileBytes(coord), canvas.active?.readTile(coord), "\(coord)")
        }

        let undone = try XCTUnwrap(try history.undo(in: stack))
        canvas.invalidate(undone.deltas.map(\.coord), layerID: undone.layerID)
        try frame(canvas, queue)
        XCTAssertTrue(layer.storedTiles.isEmpty)
        for delta in undone.deltas { XCTAssertEqual(canvas.active?.readTile(delta.coord), zeros) }
    }

    func testAlphaLockOnGPUMatchesCPU() throws {
        let device = try device()
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let stack = LayerStack(width: 1024, height: 512)
        let layer = stack.items[0].layer!
        layer.stamp(SphericalDab(center: [0, 0, -1], radius: 0.3, hardness: 0.5, color: [0.2, 0.3, 0.9, 0.7]))
        stack.update(stack.items[0].id) { $0.alphaLock = true }
        let cpu = layer.duplicate()
        let dab = SphericalDab(center: Equirect.direction(latitude: 0, longitude: 0.2), radius: 0.4, hardness: 1, color: [1, 0.5, 0, 1])
        cpu.stamp(dab, alphaLock: true)

        let canvas = StackCanvas(stack: stack, device: device)
        try frame(canvas, queue)
        XCTAssertTrue(canvas.usesFastPath)
        canvas.beginStroke()
        canvas.add([dab])
        XCTAssertNotNil(canvas.endStroke())
        XCTAssertEqual(Set(layer.storedTiles), Set(cpu.storedTiles), "le verrou alpha ne crée aucune tuile")
        for coord in cpu.storedTiles {
            let gpuPixels = layer.tileFloatPixels(coord)
            let cpuPixels = cpu.tileFloatPixels(coord)
            for i in stride(from: 0, to: gpuPixels.count, by: 97) {
                XCTAssertEqual(gpuPixels[i].w, cpuPixels[i].w, accuracy: 1e-3, "alpha conservé")
                XCTAssertEqual(gpuPixels[i].x, cpuPixels[i].x, accuracy: 1e-2)
            }
        }
    }
}
