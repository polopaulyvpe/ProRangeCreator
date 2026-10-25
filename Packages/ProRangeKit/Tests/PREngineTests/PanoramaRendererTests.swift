import Metal
import PRCore
import PREngine
import PRStorage
import XCTest

/// Tests GPU : sautés proprement si la machine n'a pas de GPU Metal (runners CI).
final class PanoramaRendererTests: XCTestCase {
    private func device() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("pas de GPU Metal sur cette machine") }
        return device
    }

    /// Texture de test : chaque texel a une couleur unique et exacte en demi-flottants.
    private func makeTestTexture(_ device: any MTLDevice, width: Int, height: Int) throws -> (any MTLTexture, [Float16]) {
        var pixels = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                pixels[o] = Float16(Float(x) / Float(width))
                pixels[o + 1] = Float16(Float(y) / Float(height))
                pixels[o + 2] = Float16(Float((x * 7 + y * 3) % 16) / 16)
                pixels[o + 3] = 1
            }
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: desc))
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: width * 8)
        }
        return (texture, pixels)
    }

    func testShaderCompiles() throws {
        _ = try PanoramaRenderer(device: try device())
    }

    /// Vue dépliée plein cadre, texture et écran de même taille : le rendu reproduit la texture pixel pour pixel.
    func testUnfoldedViewReproducesTextureExactly() throws {
        let device = try device()
        let renderer = try PanoramaRenderer(device: device)
        let (texture, pixels) = try makeTestTexture(device, width: 64, height: 32)
        var view = ViewState()
        view.mode = .unfolded
        view.morph = 1
        let uniforms = ViewUniforms(view.parameters(aspect: 2), viewportHeight: 32, textureHeight: 32)
        let out = try renderer.renderOffscreen(panorama: texture, width: 64, height: 32, uniforms: uniforms, filtering: .nearest)
        XCTAssertEqual(out, pixels)
    }

    /// En vue sphère, chaque pixel montre le texel visé par la direction de référence CPU.
    func testSphereViewMatchesCPUDirections() throws {
        let device = try device()
        let renderer = try PanoramaRenderer(device: device)
        let (texture, pixels) = try makeTestTexture(device, width: 64, height: 32)
        var view = ViewState()
        view.yaw = 2.5 // la couture passe dans le champ
        view.pitch = 0.4
        view.fov = 100 * .pi / 180
        let width = 48, height = 32
        let parameters = view.parameters(aspect: Double(width) / Double(height))
        let out = try renderer.renderOffscreen(panorama: texture, width: width, height: height,
                                               uniforms: ViewUniforms(parameters, viewportHeight: height, textureHeight: 32),
                                               filtering: .nearest)
        var mismatches = 0
        for y in 0..<height {
            for x in 0..<width {
                let ndc = SIMD2<Double>((Double(x) + 0.5) / Double(width) * 2 - 1, 1 - (Double(y) + 0.5) / Double(height) * 2)
                let d = try XCTUnwrap(parameters.direction(ndc: ndc))
                let p = Equirect.pixel(from: d, width: 64, height: 32)
                let tx = min(63, Int(p.x)), ty = min(31, Int(p.y))
                let o = (y * width + x) * 4, t = (ty * 64 + tx) * 4
                if Array(out[o..<o + 4]) != Array(pixels[t..<t + 4]) { mismatches += 1 }
            }
        }
        // Les directions qui tombent pile sur une frontière de texel peuvent différer d'un texel (float GPU vs double CPU).
        XCTAssertLessThan(mismatches, width * height / 50, "\(mismatches) pixels différents")
    }

    func testOverexposedClipAndToneMappingStayInRange() throws {
        let device = try device()
        let renderer = try PanoramaRenderer(device: device)
        let (texture, _) = try makeTestTexture(device, width: 64, height: 32)
        var view = ViewState()
        view.mode = .unfolded
        view.morph = 1
        for curve in ToneMapping.allCases {
            let uniforms = ViewUniforms(view.parameters(aspect: 2), viewportHeight: 32, textureHeight: 32, exposure: 6, toneMapping: curve)
            let out = try renderer.renderOffscreen(panorama: texture, width: 64, height: 32, uniforms: uniforms, filtering: .nearest)
            XCTAssertTrue(out.allSatisfy { $0 >= 0 && $0 <= 1.001 }, curve.label)
        }
    }
}

final class DisplayTextureTests: XCTestCase {
    func testUploadCompositesOverBackgroundAndReduces() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("pas de GPU Metal sur cette machine") }
        let layer = TiledLayer(name: "t", width: 2048, height: 1024)
        layer.stamp(SphericalDab(center: [0, 0, -1], radius: 0.3, hardness: 1, color: [1, 0, 0, 1]))
        let display = try DisplayTexture(device: device, layerWidth: 2048, maxWidth: 1024)
        XCTAssertEqual(display.factor, 2)
        XCTAssertEqual(display.texture.width, 1024)
        display.uploadAll(layer)

        func texel(_ x: Int, _ y: Int) -> [Float16] {
            var px = [Float16](repeating: 0, count: 4)
            px.withUnsafeMutableBytes { raw in
                display.texture.getBytes(raw.baseAddress!, bytesPerRow: 8, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            }
            return px
        }
        XCTAssertEqual(texel(512, 256), [1, 0, 0, 1], "centre du dab, face à -Z")
        XCTAssertEqual(texel(10, 10), [1, 1, 1, 1], "fond blanc ailleurs")
    }
}
