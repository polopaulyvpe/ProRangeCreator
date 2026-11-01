import Metal
import PRCore
import PREngine
import PRStorage
import simd
import XCTest

/// Effilement de fin : un trait repeint au lever (`replaceStroke`) doit donner exactement le trait peint directement
/// avec les dabs finaux, sur le chemin CPU comme sur le GPU.
final class StrokeReplayTests: XCTestCase {
    private func dabs(radius: Double) -> [SphericalDab] {
        (0..<30).map { i in
            var dab = SphericalDab(center: Equirect.direction(latitude: 0.1, longitude: -0.5 + Double(i) * 0.03), radius: radius,
                                   hardness: 0.6, color: [0.9, 0.3, 0.1, 0.8])
            dab.flow = 0.5
            return dab
        }
    }

    private func paint(device: (any MTLDevice)?, first: [SphericalDab]?, final: [SphericalDab]) -> TiledLayer {
        let stack = LayerStack(width: 512, height: 256)
        let base = stack.items[0].layer!
        base.stamp(SphericalDab(center: Equirect.direction(latitude: 0.1, longitude: -0.1), radius: 0.3, hardness: 0.5,
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
        canvas.beginStroke(style: StrokeStyle(color: [0.9, 0.3, 0.1]))
        if let first {
            canvas.add(first)
            frame()
            canvas.replaceStroke(with: final)
        } else {
            canvas.add(final)
        }
        _ = canvas.endStroke()
        return stack.item(canvas.activeID)!.layer!
    }

    private func assertSame(_ a: TiledLayer, _ b: TiledLayer, file: StaticString = #filePath, line: UInt = #line) {
        var worst: Float = 0
        for y in stride(from: 0, to: 256, by: 2) {
            for x in stride(from: 0, to: 512, by: 2) {
                worst = max(worst, simd_reduce_max(simd_abs(a.pixel(x: x, y: y) - b.pixel(x: x, y: y))))
            }
        }
        XCTAssertLessThan(worst, 0.004, "écart \(worst)", file: file, line: line)
    }

    func testReplacedStrokeEqualsDirectStrokeOnCPU() {
        let replayed = paint(device: nil, first: dabs(radius: 0.08), final: dabs(radius: 0.05))
        let direct = paint(device: nil, first: nil, final: dabs(radius: 0.05))
        assertSame(replayed, direct)
    }

    func testReplacedStrokeEqualsDirectStrokeOnGPU() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("pas de GPU Metal sur cette machine") }
        let replayed = paint(device: device, first: dabs(radius: 0.08), final: dabs(radius: 0.05))
        let direct = paint(device: device, first: nil, final: dabs(radius: 0.05))
        assertSame(replayed, direct)
    }
}
