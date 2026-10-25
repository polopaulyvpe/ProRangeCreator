import Metal
import PRCore
import PREngine
import PRStorage
import XCTest

/// Affichage de la sélection (assombrissement) et aperçu du contenu flottant transformé, dans le shader.
final class SelectionDisplayTests: XCTestCase {
    func testSelectionDimmingAndTransformPreview() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("pas de GPU Metal sur cette machine") }
        let renderer = try PanoramaRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let stack = LayerStack(width: 512, height: 256)
        let canvas = StackCanvas(stack: stack, device: device)

        let mask = SelectionMask(width: 512, height: 256)
        mask.apply(.rectangle([-0.5, -0.5], [0.5, 0.5]), in: ViewState().parameters(aspect: 1), mode: .replace)
        canvas.selection = mask

        func render(_ configure: (inout ViewUniforms) -> Void) throws -> [Float16] {
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            canvas.encodeFrame(into: commands)
            commands.commit()
            commands.waitUntilCompleted()
            var view = ViewState()
            view.mode = .unfolded
            view.morph = 1
            var uniforms = ViewUniforms(view.parameters(aspect: 2), viewportHeight: 256, textureHeight: 256)
            canvas.configure(&uniforms)
            configure(&uniforms)
            return try renderer.renderOffscreen(layers: try XCTUnwrap(canvas.panoramaLayers()), width: 512, height: 256,
                                                uniforms: uniforms, filtering: .nearest)
        }
        func red(_ image: [Float16], _ x: Int, _ y: Int) -> Float { Float(image[(y * 512 + x) * 4]) }

        let dimmed = try render { $0.setSelection(visible: true, transform: nil) }
        XCTAssertEqual(red(dimmed, 256, 128), 1, accuracy: 0.01, "papier blanc dans la sélection")
        XCTAssertEqual(red(dimmed, 20, 128), 0.5, accuracy: 0.01, "assombri hors sélection")

        // Contenu flottant : un disque rouge, montré déplacé de 90° vers +X.
        let floating = TiledLayer(name: "f", width: 512, height: 256)
        floating.stamp(SphericalDab(center: [0, 0, -1], radius: 0.2, hardness: 1, color: [1, 0, 0, 1]))
        canvas.setFloating(floating)
        let transform = SphericalTransform(origin: [0, 0, -1], target: [1, 0, 0])
        let preview = try render { $0.setSelection(visible: false, transform: transform) }
        let g = Float(preview[(128 * 512 + 384) * 4 + 1])
        XCTAssertEqual(g, 0, accuracy: 0.02, "disque rouge montré à +X (vert nul)")
        XCTAssertEqual(Float(preview[(128 * 512 + 256) * 4 + 1]), 1, accuracy: 0.02, "rien à l'origine (papier blanc)")
    }
}
