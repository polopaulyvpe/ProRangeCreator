import Metal
import PRCore
import PREngine
import PRStorage
import simd
import XCTest

/// Aperçu GPU de la transformation libre (coins, rotation, maillage, déplacement) comparé au collage CPU.
final class FreeTransformGPUTests: XCTestCase {
    private let width = 512
    private let height = 256

    func testPreviewMatchesCPUPaste() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("pas de GPU Metal sur cette machine") }
        let renderer = try PanoramaRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())

        let floating = TiledLayer(name: "f", width: width, height: height)
        floating.stamp(SphericalDab(center: Equirect.direction(latitude: 0.1, longitude: -0.2), radius: 0.35, hardness: 0.3,
                                    color: [1, 0.2, 0.1, 1]))
        floating.stamp(SphericalDab(center: Equirect.direction(latitude: -0.1, longitude: 0.25), radius: 0.25, hardness: 0.5,
                                    color: [0.1, 0.3, 1, 1]))
        let identity = try XCTUnwrap(FreeTransform.fitting(floating.contentDirections(step: 4)))
        var t = identity
        t.moveCorner(1, to: t.corners[1] + [0.1, 0.05])
        t.rotate(by: 0.3)
        t.warp(grabbed: [0.5, 0.5], to: try XCTUnwrap(t.targetPoint([0.5, 0.5])) + [0.05, -0.04])
        t.target = Sphere.rotation(from: t.origin, to: Equirect.direction(latitude: 0.15, longitude: 0.2)) * t.target

        func render(_ stack: LayerStack, floating: TiledLayer?, transform: FreeTransform?) throws -> [Float16] {
            let canvas = StackCanvas(stack: stack, device: device)
            if let floating { canvas.setFloating(floating) }
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            canvas.encodeFrame(into: commands)
            commands.commit()
            commands.waitUntilCompleted()
            var view = ViewState()
            view.mode = .unfolded
            view.morph = 1
            var uniforms = ViewUniforms(view.parameters(aspect: 2), viewportHeight: height, textureHeight: height)
            canvas.configure(&uniforms)
            uniforms.setSelection(visible: false, freeTransform: transform)
            return try renderer.renderOffscreen(layers: try XCTUnwrap(canvas.panoramaLayers()), width: width, height: height,
                                                uniforms: uniforms, filtering: .nearest)
        }

        let pasted = TiledLayer(name: "cpu", width: width, height: height)
        pasted.paste(floating, transform: t, filter: .nearest)
        let cpu = try render(LayerStack(width: width, height: height, format: .rgba16Float,
                                        items: [StackItem(kind: .layer(pasted), name: "cpu")]), floating: nil, transform: nil)
        let gpu = try render(LayerStack(width: width, height: height), floating: floating, transform: t)
        let still = try render(LayerStack(width: width, height: height), floating: floating, transform: identity)

        var bad = 0, moved = 0
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            var worst: Float = 0, shift: Float = 0
            for c in 0..<3 {
                worst = max(worst, abs(Float(cpu[i + c]) - Float(gpu[i + c])))
                shift = max(shift, abs(Float(gpu[i + c]) - Float(still[i + c])))
            }
            if worst > 0.08 { bad += 1 }
            if shift > 0.2 { moved += 1 }
        }
        XCTAssertLessThan(Double(bad) / Double(width * height), 0.005, "aperçu GPU = collage CPU (hors quelques bords)")
        XCTAssertGreaterThan(moved, 2000, "la transformation déplace vraiment le contenu")
    }
}
