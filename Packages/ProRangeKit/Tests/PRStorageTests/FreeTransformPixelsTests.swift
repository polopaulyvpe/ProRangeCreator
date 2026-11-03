import Foundation
import PRCore
import PRStorage
import simd
import XCTest

/// Découpe, collage transformé, filtres et deltas d'une transformation libre.
final class FreeTransformPixelsTests: XCTestCase {
    private let width = 1024
    private let height = 512

    private func at(_ layer: TiledLayer, _ d: Vec3) -> SIMD4<Float> {
        let p = Equirect.pixel(from: d, width: width, height: height)
        return layer.pixel(x: min(width - 1, Int(p.x)), y: min(height - 1, Int(p.y)))
    }

    func testCutMovePasteAndSingleHistoryEntry() throws {
        let layer = TiledLayer(name: "t", width: width, height: height)
        let dot = Equirect.direction(latitude: 0.2, longitude: 0)
        let other = Equirect.direction(latitude: -0.4, longitude: 1)
        layer.stamp(SphericalDab(center: dot, radius: 0.1, hardness: 1, color: [1, 0.5, 0, 1]))
        layer.stamp(SphericalDab(center: other, radius: 0.1, hardness: 1, color: [0, 0, 1, 1]))
        let original = layer.duplicate()
        let mask = SelectionMask(width: width, height: height)
        mask.apply(layer.floodMask(from: dot, threshold: 0.05), mode: .replace)

        var t = try XCTUnwrap(FreeTransform.fitting(mask.selectedDirections()))
        XCTAssertEqual(t.plane, .gnomonic)
        let floating = layer.masked(by: mask)
        let cut = layer.cut(selection: mask)
        XCTAssertEqual(at(layer, dot).w, 0, accuracy: 0.01, "découpé")
        XCTAssertEqual(at(layer, other).z, 1, accuracy: 1e-3, "le reste est intact")

        let target = Equirect.direction(latitude: 0.2, longitude: -1.5)
        t.target = Sphere.rotation(from: t.direction(ofPlanePoint: t.center), to: target) * t.target
        layer.beginOperation()
        layer.paste(floating, transform: t, filter: .bilinear)
        let deltas = layer.transformDeltas(cut: cut, pasted: layer.endOperation())
        XCTAssertEqual(at(layer, target).x, 1, accuracy: 0.03, "le disque orange est arrivé")
        XCTAssertEqual(at(layer, dot).w, 0, accuracy: 0.02, "et a quitté sa place")

        // Une seule entrée d'historique : ses « avant » rendent exactement le calque d'origine.
        for delta in deltas { layer.restore(delta.before, at: delta.coord) }
        for coord in Set(original.storedTiles).union(layer.storedTiles) {
            XCTAssertEqual(layer.state(of: coord), original.state(of: coord))
        }

        mask.transform(t)
        XCTAssertGreaterThan(mask.value(x: Int(Equirect.pixel(from: target, width: width, height: height).x),
                                        y: Int(Equirect.pixel(from: target, width: width, height: height).y)), 0.9,
                             "la sélection suit")
    }

    func testWholeLayerAndFilters() throws {
        let layer = TiledLayer(name: "t", width: width, height: height)
        let center = Equirect.direction(latitude: 0, longitude: 0.5)
        layer.stamp(SphericalDab(center: center, radius: 0.15, hardness: 1, color: [0.2, 0.8, 0.4, 1]))
        var t = try XCTUnwrap(FreeTransform.fitting(layer.contentDirections()))
        let floating = layer.masked(by: nil)
        let cut = layer.cut(selection: nil)
        XCTAssertTrue(layer.storedTiles.isEmpty, "sans sélection : tout le calque est découpé")
        XCTAssertFalse(cut.isEmpty)
        t.flip(horizontally: true)
        for filter in ResamplingFilter.allCases {
            let copy = layer.duplicate()
            copy.paste(floating, transform: t, filter: filter)
            XCTAssertEqual(at(copy, center).y, 0.8, accuracy: 0.02, "\(filter) : un disque retourné reste en place")
            XCTAssertEqual(at(copy, Equirect.direction(latitude: 0, longitude: 1.2)).w, 0, "\(filter)")
        }
        // Bicubique : pas de valeurs négatives ni d'alpha au-delà de 1 sur un bord net.
        let sampler = LayerSampler(floating)
        for x in stride(from: 600.0, to: 760.0, by: 0.37) {
            let v = sampler.sample(pixel: [x, 256.3], filter: .bicubic)
            XCTAssertGreaterThanOrEqual(min(v.x, v.y, v.z, v.w), 0)
            XCTAssertLessThanOrEqual(v.w, 1)
        }
    }
}
