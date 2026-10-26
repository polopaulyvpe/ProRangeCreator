import Foundation
import Metal
import PRCore
import PREngine
import PRStorage
import XCTest

/// Banc d'essai : chronomètre les opérations qui font la latence ressentie (lignes « PERF » dans le journal de la CI).
/// Ne vérifie rien d'autre que le bon déroulement : les chiffres servent à choisir quoi optimiser.
final class PerformanceBenchmarks: XCTestCase {
    private func time(_ label: String, _ body: () throws -> Void) rethrows -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        try body()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print(String(format: "PERF %@ : %.1f ms", label, ms))
        return ms
    }

    /// Pile de `count` calques, chacun couvert de traits sur environ un tiers de la sphère.
    private func paintedStack(width: Int, layers count: Int) -> LayerStack {
        let stack = LayerStack(width: width, height: width / 2)
        for l in 0..<count {
            if l > 0 { _ = stack.addLayer(above: stack.items.last!.id) }
            let layer = stack.items.last!.layer!
            for i in 0..<60 {
                let center = Equirect.direction(latitude: Double(i % 7) * 0.2 - 0.6, longitude: Double(i) * 0.4 + Double(l))
                layer.stamp(SphericalDab(center: center, radius: 0.25, hardness: 0.6, color: [0.2 + 0.1 * Float(l), 0.5, 0.8, 0.9]))
            }
        }
        return stack
    }

    func testOperationTimings() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("pas de GPU Metal sur cette machine")
        }
        for width in [2048, 4096, 8192] {
            let tag = "\(width / 1024)K"
            let stack = paintedStack(width: width, layers: 5)
            var canvas: StackCanvas!
            func frame() {
                let commands = queue.makeCommandBuffer()!
                canvas.encodeFrame(into: commands)
                commands.commit()
                commands.waitUntilCompleted()
            }
            _ = time("\(tag) ouverture de la toile (premier affichage)") {
                canvas = StackCanvas(stack: stack, device: device)
                frame()
            }
            _ = time("\(tag) image sans changement") { frame() }
            _ = time("\(tag) changement de calque actif") {
                canvas.activeID = stack.items[1].id
                canvas.setNeedsRefresh()
                frame()
            }
            var deltas: [TileDelta] = []
            _ = time("\(tag) trait de 300 dabs (peinture + fin du trait)") {
                canvas.beginStroke()
                for i in 0..<300 {
                    let center = Equirect.direction(latitude: 0.3 * sin(Double(i) * 0.05), longitude: Double(i) * 0.01)
                    canvas.add([SphericalDab(center: center, radius: 0.04, hardness: 0.8, color: [1, 0.3, 0.2, 1])])
                    if i % 20 == 0 { frame() }
                }
                frame()
                deltas = canvas.endStroke()?.deltas ?? []
            }
            print("PERF \(tag) tuiles du trait : \(deltas.count)")
            let history = UndoRedoManager()
            if let layer = stack.item(canvas.activeID)?.layer {
                history.record(HistoryEntry(name: "Trait", layerID: layer.id, deltas: deltas))
                _ = try time("\(tag) annuler le trait") {
                    if let entry = try history.undo(in: stack) {
                        canvas.invalidate(entry.deltas.map(\.coord), layerID: entry.layerID)
                    }
                    frame()
                }
            }
            _ = time("\(tag) ajout d'un calque") {
                _ = stack.addLayer(above: canvas.activeID)
                canvas.activeID = stack.items.last!.id
                canvas.setNeedsRefresh()
                frame()
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString).prrange")
            defer { try? FileManager.default.removeItem(at: url) }
            try time("\(tag) enregistrement du projet") { try ProjectPackage.save(stack: stack, to: url) }
            try time("\(tag) deuxième enregistrement") { try ProjectPackage.save(stack: stack, to: url) }
            var loaded: LayerStack!
            try time("\(tag) lecture du projet") { loaded = try ProjectPackage.loadStack(from: url).stack }
            _ = time("\(tag) ouverture : toile du projet relu") {
                canvas = StackCanvas(stack: loaded, device: device)
                frame()
            }
        }
    }
}
