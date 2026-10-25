import Foundation
import PRCore
import PRStorage
import simd
import XCTest

final class SelectionMaskTests: XCTestCase {
    private let width = 1024
    private let height = 512

    private func value(_ mask: SelectionMask, latitude: Double, longitude: Double) -> Float {
        let p = Equirect.pixel(from: Equirect.direction(latitude: latitude, longitude: longitude), width: width, height: height)
        return mask.value(x: min(width - 1, Int(p.x)), y: min(height - 1, Int(p.y)))
    }

    private var frontView: ProjectionParameters { ViewState().parameters(aspect: 1) }

    func testShapeSelectionsAndCombinations() {
        let mask = SelectionMask(width: width, height: height)
        XCTAssertTrue(mask.isEmpty)
        // Carré au centre de la vue de face (±0,5 en NDC, champ de 90° : ±26,6°).
        mask.apply(.rectangle([-0.5, -0.5], [0.5, 0.5]), in: frontView, mode: .replace)
        XCTAssertEqual(value(mask, latitude: 0, longitude: 0), 1)
        XCTAssertEqual(value(mask, latitude: 0, longitude: 0.4), 1)
        XCTAssertEqual(value(mask, latitude: 0, longitude: 0.6), 0)
        XCTAssertEqual(value(mask, latitude: 0, longitude: .pi), 0, "rien derrière la caméra")

        mask.apply(.ellipse([-0.2, -0.2], [0.2, 0.2]), in: frontView, mode: .subtract)
        XCTAssertEqual(value(mask, latitude: 0, longitude: 0), 0, "trou au centre")
        XCTAssertEqual(value(mask, latitude: 0, longitude: 0.4), 1)

        var side = ViewState()
        side.yaw = .pi / 2
        mask.apply(.polygon([[-0.3, -0.3], [0.3, -0.3], [0, 0.4]]), in: side.parameters(aspect: 1), mode: .add)
        XCTAssertEqual(value(mask, latitude: 0, longitude: .pi / 2), 1, "ajouté à droite")
        XCTAssertEqual(value(mask, latitude: 0, longitude: 0.4), 1, "l'existant est gardé")

        mask.invert()
        XCTAssertEqual(value(mask, latitude: 0, longitude: 0), 1)
        XCTAssertEqual(value(mask, latitude: 0, longitude: 0.4), 0)
        XCTAssertEqual(value(mask, latitude: 0, longitude: .pi), 1)

        mask.clear()
        XCTAssertTrue(mask.isEmpty)
    }

    func testFeatherSoftensEdges() {
        let mask = SelectionMask(width: width, height: height)
        mask.apply(.rectangle([-0.5, -0.5], [0.5, 0.5]), in: frontView, mode: .replace)
        mask.feather(radius: 3 * .pi / 180)
        XCTAssertEqual(value(mask, latitude: 0, longitude: 0), 1, accuracy: 1e-3, "intérieur intact")
        let edge = value(mask, latitude: 0, longitude: atan(0.5))
        XCTAssertGreaterThan(edge, 0.2)
        XCTAssertLessThan(edge, 0.8)
        XCTAssertEqual(value(mask, latitude: 0, longitude: 1.2), 0, accuracy: 1e-3)
    }

    func testAutomaticSelectionAndPaintingInside() {
        let layer = TiledLayer(name: "t", width: width, height: height)
        layer.stamp(SphericalDab(center: [0, 0, -1], radius: 0.3, hardness: 1, color: [0, 0, 1, 1]))
        let mask = SelectionMask(width: width, height: height)
        mask.apply(layer.floodMask(from: [0, 0, -1], threshold: 0.05), mode: .replace)
        XCTAssertEqual(value(mask, latitude: 0, longitude: 0), 1)
        XCTAssertEqual(value(mask, latitude: 0, longitude: 0.5), 0)

        // Un gros dab rouge ne peint que dans le disque sélectionné.
        let paint = TiledLayer(name: "p", width: width, height: height)
        paint.stamp(SphericalDab(center: [0, 0, -1], radius: 0.8, hardness: 1, color: [1, 0, 0, 1]),
                    selection: { mask.tileValues($0) })
        let inside = paint.pixel(x: 512, y: 256)
        XCTAssertEqual(inside.w, 1, accuracy: 1e-3)
        let p = Equirect.pixel(from: Equirect.direction(latitude: 0, longitude: 0.5), width: width, height: height)
        XCTAssertEqual(paint.pixel(x: Int(p.x), y: Int(p.y)).w, 0, "hors sélection : intact")
    }

    func testConstrainLimitsAnyOperation() {
        let layer = TiledLayer(name: "t", width: width, height: height)
        let mask = SelectionMask(width: width, height: height)
        mask.apply(.rectangle([-0.5, -0.5], [0.5, 0.5]), in: frontView, mode: .replace)
        layer.beginOperation()
        let tiles = layer.applyGradient(SphericalGradient(shape: .radial, start: [0, 0, -1], end: [0, 1, 0]),
                                        from: [0, 1, 0, 1], to: [0, 1, 0, 1], space: .perceptual)
        layer.constrainCurrentOperation(to: mask, tiles: tiles)
        let deltas = layer.endOperation()
        XCTAssertFalse(deltas.isEmpty)
        XCTAssertEqual(layer.pixel(x: 512, y: 256).w, 1, accuracy: 1e-3, "dans la sélection")
        XCTAssertEqual(layer.pixel(x: 10, y: 256).w, 0, "ailleurs : rien")
    }

    func testTransformMovesSelectedContentAndSelection() {
        let layer = TiledLayer(name: "t", width: width, height: height)
        let dot = Equirect.direction(latitude: 0.2, longitude: 0)
        layer.stamp(SphericalDab(center: dot, radius: 0.1, hardness: 1, color: [1, 0.5, 0, 1]))
        layer.stamp(SphericalDab(center: Equirect.direction(latitude: -0.4, longitude: 1), radius: 0.1, hardness: 1, color: [0, 0, 1, 1]))
        let mask = SelectionMask(width: width, height: height)
        mask.apply(layer.floodMask(from: dot, threshold: 0.05), mode: .replace)

        let target = Equirect.direction(latitude: 0.2, longitude: -1.5)
        let transform = SphericalTransform(origin: dot, target: target)
        layer.applyTransform(transform, selection: mask)
        mask.transform(transform)

        func at(_ d: Vec3) -> SIMD4<Float> {
            let p = Equirect.pixel(from: d, width: width, height: height)
            return layer.pixel(x: Int(p.x), y: Int(p.y))
        }
        XCTAssertEqual(at(target).x, 1, accuracy: 0.02, "le disque orange est arrivé")
        XCTAssertEqual(at(dot).w, 0, accuracy: 0.02, "et a quitté sa place")
        XCTAssertEqual(at(Equirect.direction(latitude: -0.4, longitude: 1)).z, 1, accuracy: 1e-3, "le reste n'a pas bougé")
        XCTAssertEqual(value(mask, latitude: 0.2, longitude: -1.5), 1, accuracy: 0.02, "la sélection suit")
        XCTAssertEqual(value(mask, latitude: 0.2, longitude: 0), 0, accuracy: 0.02)
    }

    func testMaskedCopy() {
        let layer = TiledLayer(name: "t", width: width, height: height)
        layer.fill([0.5, 0.5, 0.5, 1])
        let mask = SelectionMask(width: width, height: height)
        mask.apply(.rectangle([-0.5, -0.5], [0.5, 0.5]), in: frontView, mode: .replace)
        let floating = layer.masked(by: mask)
        XCTAssertEqual(floating.pixel(x: 512, y: 256).w, 1)
        XCTAssertEqual(floating.pixel(x: 0, y: 0).w, 0)
        XCTAssertLessThan(floating.storedTiles.count, layer.storedTiles.count)
    }
}
