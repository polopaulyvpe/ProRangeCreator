import Metal
import PRCore
import PREngine
import PRStorage
import XCTest

/// Forme, rotation et grain : le kernel GPU contre `DabEvaluator` (CPU).
final class BrushTipGPUTests: XCTestCase {
    func testShapedAndGrainedDabsMatchCPU() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("pas de GPU Metal sur cette machine") }
        let engine = try BrushEngine(device: device)
        let width = 512, height = 256
        // Forme : anneau doux ; grain : damier lissé.
        let shape = BrushTexture(name: "anneau", size: 64, values: (0..<4096).map { i -> Float in
            let x = (Float(i % 64) + 0.5) / 32 - 1, y = (Float(i / 64) + 0.5) / 32 - 1
            let r = (x * x + y * y).squareRoot()
            return max(0, 1 - abs(r - 0.6) * 4) * (x > -0.2 ? 1 : 0.3)
        })
        let grain = BrushTexture(name: "damier", size: 32, values: (0..<1024).map { i -> Float in
            (i % 32 / 4 + i / 32 / 4) % 2 == 0 ? 0.9 : 0.2
        })
        let dabs = [
            SphericalDab(center: Equirect.direction(latitude: 0.1, longitude: 0.3), radius: 0.3, hardness: 1, color: [0.9, 0.2, 0.1, 1],
                         tip: DabTip(shape: shape, rotation: 0.7)),
            SphericalDab(center: Equirect.direction(latitude: -0.2, longitude: .pi), radius: 0.25, hardness: 0.6, color: [0.1, 0.4, 0.9, 0.8],
                         tip: DabTip(grain: grain, grainScale: 0.2, grainDepth: 0.8)),
            SphericalDab(center: [0, 1, 0], radius: 0.35, hardness: 1, color: [2, 1.5, 0.5, 1],
                         tip: DabTip(shape: shape, grain: grain, rotation: -1.2, grainScale: 0.15, grainDepth: 1)),
        ]
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: desc))
        let zeros = [Float16](repeating: 0, count: width * height * 4)
        zeros.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        let commands = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        engine.encode(dabs, space: .perceptual, into: texture, commandBuffer: commands)
        commands.commit()
        commands.waitUntilCompleted()

        var gpu = [Float16](repeating: 0, count: width * height * 4)
        gpu.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        let canvas = EquirectCanvas(width: width, height: height)
        for dab in dabs { SphericalRasterizer.stamp(dab, on: canvas, space: .perceptual) }

        var outliers = 0
        var painted = 0
        for i in 0..<(width * height) {
            let ref = canvas.pixels[i]
            if ref.w > 0.05 { painted += 1 }
            let scale = max(1, ref.x)
            for k in 0..<4 where abs(Float(gpu[i * 4 + k]) - ref[k]) > 0.02 * scale { outliers += 1 }
        }
        XCTAssertGreaterThan(painted, 2000, "les dabs peignent")
        // L'échantillonneur matériel interpole avec une précision réduite : quelques écarts aux bords de la forme.
        XCTAssertLessThan(outliers, width * height / 500, "\(outliers) écarts")
    }
}
