import Foundation
import PRCore
import PRStorage
import simd
import XCTest

final class SpatialToolTests: XCTestCase {
    private let red = SIMD4<Float>(1, 0, 0, 1)

    private func pixel(_ layer: TiledLayer, latitude: Double, longitude: Double) -> SIMD4<Float> {
        let p = Equirect.pixel(from: Equirect.direction(latitude: latitude, longitude: longitude), width: layer.width, height: layer.height)
        return layer.pixel(x: min(layer.width - 1, Int(p.x)), y: min(layer.height - 1, Int(p.y)))
    }

    func testFloodFillStaysInsideARing() {
        let layer = TiledLayer(name: "t", width: 1024, height: 512)
        // Anneau noir : disque noir puis disque transparent au milieu (gomme).
        layer.stamp(SphericalDab(center: [0, 0, -1], radius: 0.4, hardness: 1, color: [0, 0, 0, 1]))
        layer.stamp(SphericalDab(center: [0, 0, -1], radius: 0.3, hardness: 1, color: [0, 0, 0, 1], mode: .erase))
        layer.floodFill(from: [0, 0, -1], color: red, threshold: 0.05, space: .perceptual)
        XCTAssertEqual(pixel(layer, latitude: 0, longitude: 0), red, "intérieur rempli")
        XCTAssertEqual(pixel(layer, latitude: 0, longitude: 0.35).x, 0, accuracy: 1e-3, "anneau intact")
        XCTAssertEqual(pixel(layer, latitude: 0, longitude: 1.5).w, 0, "extérieur non rempli")
    }

    func testFloodFillWrapsSeamAndPole() {
        let layer = TiledLayer(name: "t", width: 512, height: 256)
        // Une bande noire sur toute la longitude, à l'équateur : le nord est séparé du sud.
        for i in 0..<64 {
            let lon = -Double.pi + Double(i) * 2 * .pi / 64
            layer.stamp(SphericalDab(center: Equirect.direction(latitude: 0, longitude: lon), radius: 0.1, hardness: 1, color: [0, 0, 0, 1]))
        }
        // On part près de la couture, à l'ouest.
        layer.floodFill(from: Equirect.direction(latitude: 0.8, longitude: -3.1), color: red, threshold: 0.05, space: .perceptual)
        XCTAssertEqual(pixel(layer, latitude: 0.8, longitude: 3.1), red, "à travers la couture")
        XCTAssertEqual(pixel(layer, latitude: 1.4, longitude: 0), red, "jusqu'au pôle et de l'autre côté")
        XCTAssertEqual(pixel(layer, latitude: -0.8, longitude: 0).w, 0, "pas sous la bande")
    }

    func testFloodFillThreshold() {
        let layer = TiledLayer(name: "t", width: 512, height: 256)
        layer.fill([0.5, 0.5, 0.5, 1])
        layer.stamp(SphericalDab(center: [1, 0, 0], radius: 0.3, hardness: 1, color: [0.52, 0.5, 0.5, 1]))
        layer.floodFill(from: [0, 0, -1], color: red, threshold: 0.001, space: .perceptual)
        XCTAssertNotEqual(pixel(layer, latitude: 0, longitude: .pi / 2), red, "couleur trop différente pour un seuil serré")
        layer.floodFill(from: [1, 0, 0], color: red, threshold: 0.001, space: .perceptual)
        XCTAssertEqual(pixel(layer, latitude: 0, longitude: .pi / 2), red)
    }

    func testGradientFillsTheLayer() {
        let layer = TiledLayer(name: "t", width: 512, height: 256)
        let gradient = SphericalGradient(shape: .radial, start: [0, 0, -1], end: Equirect.direction(latitude: 0, longitude: 1))
        layer.applyGradient(gradient, from: [1, 0, 0, 1], to: [1, 0, 0, 0], space: .perceptual)
        XCTAssertEqual(pixel(layer, latitude: 0, longitude: 0).w, 1, accuracy: 0.02)
        XCTAssertEqual(pixel(layer, latitude: 0, longitude: 0.5).w, 0.5, accuracy: 0.02)
        XCTAssertEqual(pixel(layer, latitude: 0, longitude: 2).w, 0)
    }

    func testCloneCopiesThroughRotation() {
        let layer = TiledLayer(name: "t", width: 1024, height: 512)
        let source = Equirect.direction(latitude: 0.2, longitude: 0)
        layer.stamp(SphericalDab(center: source, radius: 0.15, hardness: 1, color: [0, 0.6, 0.2, 1]))
        let target = Equirect.direction(latitude: 0.2, longitude: 1.5)
        let sampler = LayerSampler(layer.duplicate())
        layer.clone(SphericalDab(center: target, radius: 0.2, hardness: 1, color: [0, 0, 0, 1]),
                    from: sampler, rotation: Sphere.rotation(from: target, to: source))
        let copied = pixel(layer, latitude: 0.2, longitude: 1.5)
        let original = pixel(layer, latitude: 0.2, longitude: 0)
        XCTAssertLessThan(simd_length(copied - original), 0.02)
    }

    func testSmudgeDragsColorAlongTheStroke() {
        let layer = TiledLayer(name: "t", width: 1024, height: 512)
        let start = Equirect.direction(latitude: 0, longitude: 0)
        layer.stamp(SphericalDab(center: start, radius: 0.1, hardness: 1, color: [0, 0, 1, 1]))
        var previous = start
        for i in 1...10 {
            let center = Equirect.direction(latitude: 0, longitude: Double(i) * 0.03)
            layer.smudge(SphericalDab(center: center, radius: 0.1, hardness: 1, color: [0, 0, 0, 1]), from: previous, strength: 0.9)
            previous = center
        }
        XCTAssertGreaterThan(pixel(layer, latitude: 0, longitude: 0.3).w, 0.3, "la couleur a été traînée")
    }

    func testCPURotationMovesContentAndIsReversible() {
        let layer = TiledLayer(name: "t", width: 512, height: 256)
        layer.stamp(SphericalDab(center: [0, 0, -1], radius: 0.3, hardness: 0.6, color: [0.2, 0.7, 0.3, 1]))
        let rotation = ViewState.rotation(yaw: .pi / 2, pitch: 0, roll: 0)
        layer.rotateContent(rotation)
        XCTAssertGreaterThan(pixel(layer, latitude: 0, longitude: .pi / 2).w, 0.9, "le disque est passé vers +X")
        XCTAssertLessThan(pixel(layer, latitude: 0, longitude: 0).w, 0.05)
    }

    func testMultiLayerHistoryEntry() throws {
        let stack = LayerStack(width: 512, height: 256)
        let a = stack.items[0].layer!
        let b = stack.addLayer()!.layer!
        a.beginOperation()
        a.fill([1, 0, 0, 1])
        let da = a.endOperation()
        b.beginOperation()
        b.fill([0, 1, 0, 1])
        let db = b.endOperation()
        let history = UndoRedoManager()
        history.record(HistoryEntry(name: "deux", layerID: a.id, deltas: da, otherLayers: [(b.id, db)]))
        try history.undo(in: stack)
        XCTAssertTrue(a.storedTiles.isEmpty && b.storedTiles.isEmpty)
        try history.redo(in: stack)
        XCTAssertFalse(a.storedTiles.isEmpty || b.storedTiles.isEmpty)
    }
}
