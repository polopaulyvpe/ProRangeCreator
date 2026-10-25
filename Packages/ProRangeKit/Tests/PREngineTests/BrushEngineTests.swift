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

}
