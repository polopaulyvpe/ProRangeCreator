import Metal
import PRCore
import PREngine
import PRStorage
import simd
import XCTest

/// Filtres GPU contre leurs références CPU, et aperçu en direct dans la toile.
final class FilterEngineTests: XCTestCase {
    private let width = 256
    private let height = 128

    private func device() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("pas de GPU Metal sur cette machine") }
        return device
    }

    private func paintedLayer() -> TiledLayer {
        let layer = TiledLayer(name: "t", width: width, height: height)
        layer.stamp(SphericalDab(center: [0, 0, -1], radius: 0.6, hardness: 0.4, color: [0.9, 0.3, 0.1, 1]))
        layer.stamp(SphericalDab(center: [0, 1, 0], radius: 0.5, hardness: 0.8, color: [0.1, 0.5, 0.9, 0.8]))
        layer.stamp(SphericalDab(center: Equirect.direction(latitude: -0.3, longitude: .pi), radius: 0.4, hardness: 1, color: [2.5, 2, 1.5, 1]))
        return layer
    }

    private func read(_ texture: any MTLTexture) -> [SIMD4<Float>] {
        var halves = [Float16](repeating: 0, count: width * height * 4)
        halves.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        return (0..<(width * height)).map { SIMD4<Float>(Float(halves[$0 * 4]), Float(halves[$0 * 4 + 1]), Float(halves[$0 * 4 + 2]), Float(halves[$0 * 4 + 3])) }
    }

    private func run(_ op: FilterOperation, on layer: TiledLayer, engine: FilterEngine) throws -> [SIMD4<Float>] {
        let source = try engine.upload(layer)
        let destination = try engine.makeTexture(width: width, height: height)
        try engine.run(op, source: source, destination: destination)
        return read(destination)
    }

    /// Part des valeurs qui diffèrent de plus de `tolerance` (relatif au-delà de 1).
    private func mismatchRatio(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>], tolerance: Float = 0.01) -> Double {
        var bad = 0
        for i in a.indices {
            let scale = max(1, simd_reduce_max(simd_abs(b[i])))
            if simd_reduce_max(simd_abs(a[i] - b[i])) > tolerance * scale { bad += 1 }
        }
        return Double(bad) / Double(a.count)
    }

    func testAdjustmentsMatchCPU() throws {
        let engine = try FilterEngine(device: try device())
        let layer = paintedLayer()
        let pixels = layer.allPixels()
        let adjustments: [Adjustment] = [
            .hueSaturation(hue: 0.2, saturation: 0.4, brightness: -0.2),
            .colorBalance(shadows: [0.3, 0, -0.2], midtones: [0, 0.4, 0], highlights: [-0.3, 0, 0.5]),
            .curves(ToneCurve(points: [[0, 0.1], [0.3, 0.2], [0.7, 0.9], [1, 1]])),
            .curves(ToneCurve(points: [[0, 0], [2, 1.5], [4, 4]], maxInput: 4)),
            .gradientMap(dark: [0.1, 0, 0.3], light: [1, 0.9, 0.5]),
            .recolor(from: 0.05, to: 0.6, tolerance: 0.15),
        ]
        for adjustment in adjustments {
            let gpu = try run(.adjustment(adjustment), on: layer, engine: engine)
            let cpu = pixels.map { adjustment.apply($0) }
            XCTAssertLessThan(mismatchRatio(gpu, cpu), 0.01, "\(adjustment.label)")
        }
    }

    func testBlurNoiseAndChromaticMatchCPU() throws {
        let engine = try FilterEngine(device: try device())
        let layer = paintedLayer()
        let pixels = layer.allPixels()

        let blurGPU = try run(.filter(.gaussianBlur(radius: 0.08)), on: layer, engine: engine)
        let blurCPU = FilterReference.separableBlur(pixels, width: width, height: height, sigma: 0.08)
        XCTAssertLessThan(mismatchRatio(blurGPU, blurCPU), 0.01, "flou")

        let cell = Double.pi / Double(height)
        let noiseGPU = try run(.filter(.noise(amount: 0.1, cell: cell, seed: 5, monochrome: false)), on: layer, engine: engine)
        let noiseCPU = FilterReference.noise(pixels, width: width, height: height, amount: 0.1, cell: cell, seed: 5, monochrome: false)
        // Aux frontières de cellules, le GPU (float) et le CPU (double) peuvent tomber dans des cellules voisines.
        XCTAssertLessThan(mismatchRatio(noiseGPU, noiseCPU), 0.05, "bruit")

        let center = Equirect.direction(latitude: 0.1, longitude: 0.2)
        let chromaGPU = try run(.filter(.chromaticAberration(center: center, strength: 0.03)), on: layer, engine: engine)
        let chromaCPU = FilterReference.chromaticAberration(layer, center: center, strength: 0.03)
        XCTAssertLessThan(mismatchRatio(chromaGPU, chromaCPU, tolerance: 0.03), 0.02, "aberration chromatique")
    }

    func testOtherFiltersBehave() throws {
        let engine = try FilterEngine(device: try device())
        let uniform = TiledLayer(name: "u", width: width, height: height)
        uniform.fill([0.4, 0.4, 0.4, 1])
        for filter: SphereFilter in [.motionBlur(length: 0.2, angle: 0.7), .sharpen(radius: 0.05, amount: 2)] {
            let out = try run(.filter(filter), on: uniform, engine: engine)
            XCTAssertLessThan(simd_reduce_max(simd_abs(out[width * 40 + 17] - SIMD4<Float>(0.4, 0.4, 0.4, 1))), 0.01, "\(filter.label) : uniforme intact")
        }
        // Bloom : rien sous le seuil, un halo autour de ce qui dépasse.
        let layer = paintedLayer()
        let bloom = try run(.filter(.bloom(threshold: 1.5, radius: 0.1, intensity: 1)), on: layer, engine: engine)
        let pixels = layer.allPixels()
        let dark = 64 * width + 128 // centre du disque orange (< seuil)
        XCTAssertEqual(bloom[dark].x, pixels[dark].x, accuracy: 0.02, "sous le seuil : intact")
        let hot = Equirect.pixel(from: Equirect.direction(latitude: -0.3, longitude: .pi - 0.5), width: width, height: height)
        let near = Int(hot.y) * width + Int(hot.x)
        XCTAssertGreaterThan(bloom[near].x, pixels[near].x + 0.01, "halo à côté du disque HDR")
    }

    func testLivePreviewApplyAndCancelInCanvas() throws {
        let device = try device()
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let stack = LayerStack(width: 512, height: 256)
        let layer = stack.items[0].layer!
        layer.stamp(SphericalDab(center: [0, 0, -1], radius: 0.5, hardness: 1, color: [0.8, 0.2, 0.2, 1]))
        let canvas = StackCanvas(stack: stack, device: device)
        func frame() throws {
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            canvas.encodeFrame(into: commands)
            commands.commit()
            commands.waitUntilCompleted()
        }
        try frame()
        let original = layer.tileBytes(TileCoord(x: 1, y: 0))

        canvas.beginFilter()
        XCTAssertTrue(canvas.filterPreviewIsLive)
        canvas.previewFilter(.adjustment(.hueSaturation(hue: 0, saturation: -1, brightness: 0)))
        let preview = canvas.active?.readTile(TileCoord(x: 1, y: 0))
        XCTAssertNotEqual(preview, original, "l'aperçu s'affiche dans la texture du calque")
        XCTAssertNil(canvas.endFilter(apply: false))
        try frame()
        XCTAssertEqual(canvas.active?.readTile(TileCoord(x: 1, y: 0)), original, "annulé : la texture revient au calque")
        XCTAssertEqual(layer.tileBytes(TileCoord(x: 1, y: 0)), original, "le calque n'a pas bougé")

        canvas.beginFilter()
        canvas.previewFilter(.adjustment(.hueSaturation(hue: 0, saturation: -1, brightness: 0)))
        let result = try XCTUnwrap(canvas.endFilter(apply: true))
        XCTAssertFalse(result.deltas.isEmpty)
        let p = layer.pixel(x: 256, y: 128)
        XCTAssertEqual(p.x, p.y, accuracy: 2e-3, "appliqué : désaturé")
    }
}
