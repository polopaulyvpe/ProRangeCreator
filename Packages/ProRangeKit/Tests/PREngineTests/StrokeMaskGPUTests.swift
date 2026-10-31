import Metal
import PRCore
import PREngine
import PRStorage
import XCTest

/// Trait à masque (glacis, flux, pinceau double) : `BrushEngine.encodeStroke` contre `TiledLayer.stamp(_:into:)` (CPU).
final class StrokeMaskGPUTests: XCTestCase {
    func testMaskedStrokeMatchesCPUReference() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("pas de GPU Metal sur cette machine") }
        let engine = try BrushEngine(device: device)
        let width = 512, height = 256
        let background = SIMD4<Float>(0.05, 0.1, 0.2, 0.5)
        let shape = BrushTexture(name: "tache", size: 32, values: (0..<1024).map { i -> Float in
            let x = (Float(i % 32) + 0.5) / 16 - 1, y = (Float(i / 32) + 0.5) / 16 - 1
            return max(0, 1 - (x * x + y * y)) * (i % 7 == 0 ? 0.5 : 1)
        })
        let grain = BrushTexture(name: "damier", size: 16, values: (0..<256).map { i in (i % 16 / 4 + i / 16 / 4) % 2 == 0 ? 0.9 : 0.3 })
        // Un trait le long de l'équateur, qui revient sur lui-même ; secondaire plus large, avec grain.
        var dabs: [SphericalDab] = []
        for i in 0..<24 {
            let longitude = -0.6 + Double(i % 16) * 0.08
            var primary = SphericalDab(center: Equirect.direction(latitude: 0.05 * sin(Double(i)), longitude: longitude), radius: 0.12,
                                       hardness: 0.7, color: [0.9, 0.4, 0.1, Float(0.4 + 0.02 * Double(i))],
                                       tip: i % 3 == 0 ? DabTip(shape: shape, rotation: Double(i)) : nil)
            primary.flow = 0.6
            dabs.append(primary)
            var secondary = SphericalDab(center: Equirect.direction(latitude: 0, longitude: longitude + 0.03), radius: 0.2, hardness: 0.5,
                                         color: [0.9, 0.4, 0.1, 0.9], tip: DabTip(grain: grain, grainScale: 0.1, grainDepth: 0.8))
            secondary.secondary = true
            dabs.append(secondary)
        }
        let cases: [(BlendSpace, DualBlendMode?)] = [(.perceptual, .hardMix), (.linear, .multiply), (.perceptual, nil)]
        for (space, dual) in cases {
            let style = StrokeStyle(color: [0.9, 0.4, 0.1], capsPrimary: true, capsSecondary: false, dual: dual)

            let layer = TiledLayer(name: "cpu", width: width, height: height, format: .rgba16Float)
            layer.fill(background)
            let buffer = StrokeBuffer()
            for dab in dabs { layer.stamp(dab, into: buffer, style: style, space: space) }

            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .shared
            let texture = try XCTUnwrap(device.makeTexture(descriptor: desc))
            let filled = (0..<(width * height)).flatMap { _ in [Float16(background.x), Float16(background.y), Float16(background.z), Float16(background.w)] }
            filled.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
            let original = try XCTUnwrap(engine.makeStrokeTexture(width: width, height: height))
            let mask = try XCTUnwrap(engine.makeStrokeTexture(width: width, height: height))
            let queue = try XCTUnwrap(device.makeCommandQueue())
            // Deux envois, comme deux images successives : le second ne recopie pas les tuiles déjà connues.
            var known = Set<TileCoord>()
            for half in [dabs[0..<20], dabs[20...]] {
                let commands = try XCTUnwrap(queue.makeCommandBuffer())
                known.formUnion(engine.encodeStroke(Array(half), style: style, space: space, layer: texture, original: original, mask: mask,
                                                    known: known, commandBuffer: commands))
                commands.commit()
                commands.waitUntilCompleted()
            }
            XCTAssertTrue(buffer.touchedTiles.isSubset(of: known), "le GPU recalcule au moins les tuiles peintes par le CPU")

            var gpu = [Float16](repeating: 0, count: width * height * 4)
            gpu.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
            var outliers = 0
            var changed = 0
            for y in 0..<height {
                for x in 0..<width {
                    let ref = layer.pixel(x: x, y: y)
                    if abs(ref.w - background.w) > 0.05 { changed += 1 }
                    for k in 0..<4 where abs(Float(gpu[(y * width + x) * 4 + k]) - ref[k]) > 0.02 { outliers += 1 }
                }
            }
            XCTAssertGreaterThan(changed, 1000, "\(space) \(String(describing: dual)) : le trait peint")
            // Bords de forme (échantillonneur matériel) et seuil du mélange maximal : quelques écarts tolérés.
            XCTAssertLessThan(outliers, width * height / 200, "\(space) \(String(describing: dual)) : \(outliers) écarts")
        }
    }
}
