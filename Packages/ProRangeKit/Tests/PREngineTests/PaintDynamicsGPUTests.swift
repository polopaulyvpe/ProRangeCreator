import Metal
import PRCore
import PREngine
import PRStorage
import simd
import XCTest

/// Couleur par tampon (dynamique de couleur, mélange humide) et anticipation du Pencil, sur la toile :
/// le GPU doit donner le même trait que le CPU, et l'anticipation ne doit laisser aucune trace.
final class PaintDynamicsGPUTests: XCTestCase {
    private let style = StrokeStyle(color: [0.9, 0.3, 0.1], varyingColor: true)

    /// Trait qui revient sur lui-même, une couleur différente par dab.
    private func dabs(from start: Int, count: Int) -> [SphericalDab] {
        (start..<(start + count)).map { i in
            let hue = Float(i % 5) / 5
            var dab = SphericalDab(center: Equirect.direction(latitude: 0.1 * sin(Double(i) * 0.7), longitude: -0.5 + Double(i % 18) * 0.04),
                                   radius: 0.07, hardness: 0.6, color: [hue, 1 - hue, 0.3 + hue * 0.5, 0.7])
            dab.flow = i % 2 == 0 ? 0.5 : 1
            return dab
        }
    }

    private func paint(device: (any MTLDevice)?, style: StrokeStyle, steps: [(real: [SphericalDab], predicted: [SphericalDab])]) -> TiledLayer {
        let stack = LayerStack(width: 512, height: 256)
        let base = stack.items[0].layer!
        base.stamp(SphericalDab(center: Equirect.direction(latitude: 0.1, longitude: -0.2), radius: 0.3, hardness: 0.5,
                                color: [0.1, 0.4, 0.9, 1]))
        let canvas = StackCanvas(stack: stack, device: device)
        let queue = device?.makeCommandQueue()
        func frame() {
            guard let commands = queue?.makeCommandBuffer() else { return }
            canvas.encodeFrame(into: commands)
            commands.commit()
            commands.waitUntilCompleted()
        }
        frame()
        canvas.beginStroke(style: style)
        for step in steps {
            canvas.add(step.real)
            canvas.setPrediction(step.predicted)
            frame()
        }
        _ = canvas.endStroke()
        return stack.item(canvas.activeID)!.layer!
    }

    private func worstDifference(_ a: TiledLayer, _ b: TiledLayer) -> Float {
        var worst: Float = 0
        for y in stride(from: 0, to: 256, by: 2) {
            for x in stride(from: 0, to: 512, by: 2) {
                worst = max(worst, simd_reduce_max(simd_abs(a.pixel(x: x, y: y) - b.pixel(x: x, y: y))))
            }
        }
        return worst
    }

    func testVaryingColorStrokeMatchesCPU() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("pas de GPU Metal sur cette machine") }
        let steps = [(real: dabs(from: 0, count: 20), predicted: [SphericalDab]()), (real: dabs(from: 20, count: 20), predicted: [])]
        let cpu = paint(device: nil, style: style, steps: steps)
        let gpu = paint(device: device, style: style, steps: steps)
        XCTAssertLessThan(worstDifference(cpu, gpu), 0.004)
        // Et la couleur varie vraiment : le trait n'est pas d'une seule couleur.
        let plain = paint(device: nil, style: StrokeStyle(color: [0.9, 0.3, 0.1]), steps: steps)
        XCTAssertGreaterThan(worstDifference(cpu, plain), 0.05)
    }

    func testMultiplyStrokeMatchesCPU() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("pas de GPU Metal sur cette machine") }
        let steps = [(real: dabs(from: 0, count: 30), predicted: [SphericalDab]())]
        for multiply in [StrokeStyle(color: [0.9, 0.8, 0.3], multiply: true), StrokeStyle(color: [0.9, 0.3, 0.1], varyingColor: true, multiply: true)] {
            let cpu = paint(device: nil, style: multiply, steps: steps)
            let gpu = paint(device: device, style: multiply, steps: steps)
            XCTAssertLessThan(worstDifference(cpu, gpu), 0.004)
            var normal = multiply
            normal.multiply = false
            XCTAssertGreaterThan(worstDifference(cpu, paint(device: nil, style: normal, steps: steps)), 0.05, "le fond bleu fonce le trait")
        }
    }

    func testPredictionLeavesNoTrace() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("pas de GPU Metal sur cette machine") }
        // Prédictions faussées exprès (décalées vers le nord, sur des tuiles que le trait ne touche jamais).
        func wrong(_ dabs: [SphericalDab]) -> [SphericalDab] {
            dabs.map { d in
                var p = d
                p.center = simd_normalize(d.center + [0, 0.6, 0])
                return p
            }
        }
        for style in [StrokeStyle(color: [0.9, 0.3, 0.1]), style] {
            let a = dabs(from: 0, count: 15), b = dabs(from: 15, count: 15), c = dabs(from: 30, count: 10)
            let predicted = paint(device: device, style: style, steps: [(a, wrong(b)), (b, wrong(c) + c), (c, wrong(a))])
            let direct = paint(device: device, style: style, steps: [(a + b + c, [])])
            XCTAssertLessThan(worstDifference(predicted, direct), 0.004)
        }
    }
}
