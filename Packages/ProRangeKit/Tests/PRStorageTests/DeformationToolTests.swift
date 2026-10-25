import Foundation
import PRCore
import PRStorage
import simd
import XCTest

final class DeformationToolTests: XCTestCase {
    private func pixel(_ layer: TiledLayer, _ d: Vec3) -> SIMD4<Float> {
        let p = Equirect.pixel(from: d, width: layer.width, height: layer.height)
        return layer.pixel(x: min(layer.width - 1, Int(p.x)), y: min(layer.height - 1, Int(p.y)))
    }

    func testLiquifyPushMovesContentAlongTheStroke() {
        let layer = TiledLayer(name: "t", width: 1024, height: 512)
        let start = Equirect.direction(latitude: 0, longitude: 0)
        layer.stamp(SphericalDab(center: start, radius: 0.08, hardness: 1, color: [1, 0, 0, 1]))
        var previous = start
        for i in 1...8 {
            let center = Equirect.direction(latitude: 0, longitude: Double(i) * 0.02)
            layer.liquify(SphericalDab(center: center, radius: 0.25, hardness: 0.2, color: [0, 0, 0, 1]),
                          mode: .push, from: previous, strength: 1)
            previous = center
        }
        XCTAssertGreaterThan(pixel(layer, Equirect.direction(latitude: 0, longitude: 0.12)).w, 0.5, "le disque a été poussé vers l'est")
        XCTAssertLessThan(pixel(layer, Equirect.direction(latitude: 0, longitude: -0.06)).w, 0.5, "l'arrière s'est vidé")
    }

    func testTwirlAndPinchKeepTheCenter() {
        for mode in [LiquifyMode.twirl, .pinch, .expand] {
            let layer = TiledLayer(name: "t", width: 1024, height: 512)
            layer.stamp(SphericalDab(center: [0, 0, -1], radius: 0.05, hardness: 1, color: [0, 1, 0, 1]))
            layer.stamp(SphericalDab(center: Equirect.direction(latitude: 0, longitude: 0.15), radius: 0.04, hardness: 1, color: [0, 0, 1, 1]))
            let before = pixel(layer, Equirect.direction(latitude: 0, longitude: 0.15))
            layer.liquify(SphericalDab(center: [0, 0, -1], radius: 0.4, hardness: 0, color: [0, 0, 0, 1]),
                          mode: mode, from: [0, 0, -1], strength: 1)
            XCTAssertEqual(pixel(layer, [0, 0, -1]).y, 1, accuracy: 0.05, "\(mode) : le centre ne bouge pas")
            XCTAssertNotEqual(pixel(layer, Equirect.direction(latitude: 0, longitude: 0.15)), before, "\(mode) : autour, ça bouge")
        }
    }

    func testPlaceImageFacesTheViewDirection() {
        let layer = TiledLayer(name: "t", width: 1024, height: 512)
        // Image 4×2 : moitié gauche rouge, moitié droite bleue.
        var image = [SIMD4<Float>](repeating: .zero, count: 8)
        for y in 0..<2 {
            for x in 0..<4 { image[y * 4 + x] = x < 2 ? [1, 0, 0, 1] : [0, 0, 1, 1] }
        }
        let center = Equirect.direction(latitude: 0, longitude: 1)
        layer.placeImage(image, width: 4, height: 2, center: center, angularWidth: 0.6)
        XCTAssertEqual(pixel(layer, Equirect.direction(latitude: 0, longitude: 0.9)).x, 1, accuracy: 0.05, "gauche rouge")
        XCTAssertEqual(pixel(layer, Equirect.direction(latitude: 0, longitude: 1.1)).z, 1, accuracy: 0.05, "droite bleue")
        XCTAssertEqual(pixel(layer, Equirect.direction(latitude: 0.3, longitude: 1)).w, 0, "au-dessus : rien (image 2:1)")
        XCTAssertEqual(pixel(layer, Equirect.direction(latitude: 0, longitude: 1.4)).w, 0, "au-delà de la largeur")
    }

    func testDistortMovesContent() {
        let layer = TiledLayer(name: "t", width: 1024, height: 512)
        let origin = Equirect.direction(latitude: 0, longitude: 0)
        layer.stamp(SphericalDab(center: origin, radius: 0.1, hardness: 1, color: [1, 1, 0, 1]))
        var distort = SphericalDistort(origin: origin, halfAngle: 0.3)
        let shift = Sphere.rotation(from: origin, to: Equirect.direction(latitude: 0, longitude: 0.25))
        for i in 0..<4 { distort.moveCorner(i, to: shift * distort.targetDirections[i]) }
        layer.applyDistort(distort, selection: nil)
        XCTAssertGreaterThan(pixel(layer, Equirect.direction(latitude: 0, longitude: 0.25)).w, 0.9, "le disque a suivi les coins")
        XCTAssertLessThan(pixel(layer, Equirect.direction(latitude: 0, longitude: -0.05)).w, 0.1)
    }
}
