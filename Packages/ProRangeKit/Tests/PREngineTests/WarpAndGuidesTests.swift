import Metal
import PRCore
import PREngine
import PRStorage
import simd
import XCTest

final class WarpAndGuidesTests: XCTestCase {
    private func device() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("pas de GPU Metal sur cette machine") }
        return device
    }

    func testGPURotationMatchesCPUReferenceAndUndoes() throws {
        let device = try device()
        let warp = try WarpEngine(device: device)
        let layer = TiledLayer(name: "t", width: 512, height: 256)
        layer.stamp(SphericalDab(center: [0, 0, -1], radius: 0.4, hardness: 0.5, color: [0.9, 0.3, 0.1, 1]))
        layer.stamp(SphericalDab(center: [0, 1, 0], radius: 0.3, hardness: 1, color: [0.1, 0.4, 0.9, 0.8]))
        let original = layer.duplicate()
        let reference = layer.duplicate()
        let rotation = ViewState.rotation(yaw: 0.7, pitch: 0.4, roll: -0.2)

        let deltas = try warp.rotate(layer, by: rotation)
        XCTAssertFalse(deltas.isEmpty)
        reference.rotateContent(rotation)

        var worst: Float = 0
        var outliers = 0
        for ty in 0..<layer.tilesDown {
            for tx in 0..<layer.tilesAcross {
                let coord = TileCoord(x: tx, y: ty)
                let gpu = layer.tileFloatPixels(coord)
                let cpu = reference.tileFloatPixels(coord)
                for i in gpu.indices {
                    let diff = simd_reduce_max(simd_abs(gpu[i] - cpu[i]))
                    worst = max(worst, diff)
                    if diff > 0.02 { outliers += 1 }
                }
            }
        }
        // Le GPU filtre en demi-flottants avec une précision de coordonnées moindre ; les bords des disques peuvent différer d'un texel.
        XCTAssertLessThan(outliers, 512 * 256 / 100, "\(outliers) écarts > 0,02 (pire \(worst))")

        for delta in deltas { layer.restore(delta.before, at: delta.coord) }
        for coord in Set(layer.storedTiles + original.storedTiles) {
            XCTAssertEqual(layer.tileBytes(coord), original.tileBytes(coord), "annulation exacte")
        }
    }

    func testGuidesAndRotationPreviewInShader() throws {
        let device = try device()
        let renderer = try PanoramaRenderer(device: device)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 64, height: 32, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: desc))
        var pixels = [Float16](repeating: 0, count: 64 * 32 * 4)
        for y in 0..<32 {
            for x in 0..<64 {
                let o = (y * 64 + x) * 4
                pixels[o] = Float16(Float(x) / 64)
                pixels[o + 3] = 1
            }
        }
        pixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, 64, 32), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64 * 8) }

        var view = ViewState()
        view.mode = .unfolded
        view.morph = 1
        let base = ViewUniforms(view.parameters(aspect: 2), viewportHeight: 32, textureHeight: 32)
        let plain = try renderer.renderOffscreen(panorama: texture, width: 64, height: 32, uniforms: base, filtering: .nearest)

        var withGuides = base
        withGuides.setGuides(enabled: true, spacingDegrees: 45)
        let guided = try renderer.renderOffscreen(panorama: texture, width: 64, height: 32, uniforms: withGuides, filtering: .nearest)
        let horizonRow = 15 // juste au-dessus de l'équateur
        XCTAssertNotEqual(Array(guided[(horizonRow * 64 * 4)..<((horizonRow + 1) * 64 * 4)]),
                          Array(plain[(horizonRow * 64 * 4)..<((horizonRow + 1) * 64 * 4)]), "horizon tracé")
        // Rangée 4 (≈ 65° de latitude), colonne 12 (≈ −110° de longitude) : loin de toute ligne tous les 45°.
        XCTAssertEqual(guided[(4 * 64 + 12) * 4], plain[(4 * 64 + 12) * 4], "rien entre les lignes")

        var rotated = base
        rotated.setContentRotation(ViewState.rotation(yaw: .pi / 2, pitch: 0, roll: 0))
        let preview = try renderer.renderOffscreen(panorama: texture, width: 64, height: 32, uniforms: rotated, filtering: .nearest)
        // Un quart de tour en lacet décale le contenu d'un quart de largeur.
        let x = 40
        XCTAssertEqual(Float(preview[(16 * 64 + x) * 4]), Float(plain[(16 * 64 + (x - 16)) * 4]), accuracy: 0.02)
    }
}
