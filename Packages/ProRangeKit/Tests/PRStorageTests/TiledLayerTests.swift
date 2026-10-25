import Foundation
import PRCore
import PRStorage
import XCTest

/// Générateur déterministe pour des tests reproductibles.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func randomDab(_ rng: inout SplitMix64) -> SphericalDab {
    let lat = Double.random(in: -.pi / 2 ... .pi / 2, using: &rng)
    let lon = Double.random(in: -.pi ... .pi, using: &rng)
    let color = SIMD4<Float>(Float.random(in: 0...1, using: &rng), Float.random(in: 0...1, using: &rng),
                             Float.random(in: 0...1, using: &rng), Float.random(in: 0.2...1, using: &rng))
    return SphericalDab(center: Equirect.direction(latitude: lat, longitude: lon),
                        radius: Double.random(in: 0.02...0.3, using: &rng),
                        hardness: Double.random(in: 0...1, using: &rng), color: color)
}

/// Contenu complet d'un calque, tuile par tuile, en octets bruts.
func dump(_ layer: TiledLayer) -> [[UInt8]] {
    var out: [[UInt8]] = []
    for ty in 0..<layer.tilesDown {
        for tx in 0..<layer.tilesAcross { out.append(layer.tileBytes(TileCoord(x: tx, y: ty))) }
    }
    return out
}

final class TiledLayerTests: XCTestCase {
    func testUntouchedLayerStoresNothing() {
        let layer = TiledLayer(name: "vide", width: 16384, height: 8192)
        XCTAssertEqual(layer.tilesAcross, 64)
        XCTAssertEqual(layer.tilesDown, 32)
        XCTAssertTrue(layer.storedTiles.isEmpty)
        XCTAssertEqual(layer.residentBytes, 0)
        XCTAssertEqual(layer.pixel(x: 12345, y: 4321), .zero)
    }

    /// Un dab sur un calque vide donne la même chose que la toile de référence, arrondie en demi-flottants.
    func testStampMatchesReferenceCanvas() {
        var rng = SplitMix64(state: 7)
        for _ in 0..<6 {
            let dab = randomDab(&rng)
            let layer = TiledLayer(name: "t", width: 1024, height: 512)
            let canvas = EquirectCanvas(width: 1024, height: 512)
            layer.stamp(dab)
            SphericalRasterizer.stamp(dab, on: canvas)
            for y in stride(from: 0, to: 512, by: 3) {
                for x in stride(from: 0, to: 1024, by: 3) {
                    let ref = canvas[x, y]
                    let rounded = SIMD4<Float>(Float(Float16(ref.x)), Float(Float16(ref.y)), Float(Float16(ref.z)), Float(Float16(ref.w)))
                    XCTAssertEqual(layer.pixel(x: x, y: y), rounded, "x=\(x) y=\(y)")
                }
            }
        }
    }

    func testSmallDabOnlyCreatesNearbyTiles() {
        let layer = TiledLayer(name: "t", width: 4096, height: 2048)
        let dab = SphericalDab(center: Equirect.direction(latitude: 0.1, longitude: 0.2), radius: 0.01, hardness: 1, color: [1, 0, 0, 1])
        let touched = layer.stamp(dab)
        XCTAssertFalse(touched.isEmpty)
        XCTAssertLessThanOrEqual(touched.count, 4)
        XCTAssertEqual(Set(layer.storedTiles), touched)
    }

    func testDabAroundPoleAndSeamTouchesWrappedTiles() {
        let layer = TiledLayer(name: "t", width: 2048, height: 1024)
        layer.stamp(SphericalDab(center: [0, 1, 0], radius: 0.2, hardness: 1, color: [1, 1, 1, 1]))
        let topRow = Set(layer.storedTiles.filter { $0.y == 0 }.map(\.x))
        XCTAssertEqual(topRow, Set(0..<layer.tilesAcross), "un dab au pôle couvre toute la rangée")

        let seam = TiledLayer(name: "s", width: 2048, height: 1024)
        seam.stamp(SphericalDab(center: Equirect.direction(latitude: 0, longitude: .pi), radius: 0.05, hardness: 1, color: [1, 1, 1, 1]))
        let columns = Set(seam.storedTiles.map(\.x))
        XCTAssertTrue(columns.contains(0) && columns.contains(seam.tilesAcross - 1), "le dab passe la couture")
    }

    func testFillIsUniformAndZeroFillEmpties() {
        let layer = TiledLayer(name: "t", width: 2048, height: 1024)
        layer.fill([1, 1, 1, 1])
        XCTAssertEqual(layer.storedTiles.count, layer.tilesAcross * layer.tilesDown)
        XCTAssertEqual(layer.residentBytes, layer.storedTiles.count * LayerPixelFormat.rgba16Float.bytesPerPixel)
        XCTAssertEqual(layer.pixel(x: 1000, y: 3), [1, 1, 1, 1])
        layer.fill(.zero)
        XCTAssertTrue(layer.storedTiles.isEmpty)
    }

    func testCompactKeepsPixelsAndSavesMemory() {
        var rng = SplitMix64(state: 3)
        let layer = TiledLayer(name: "t", width: 2048, height: 1024)
        for _ in 0..<10 { layer.stamp(randomDab(&rng)) }
        let before = dump(layer)
        let resident = layer.residentBytes
        layer.compact()
        XCTAssertLessThan(layer.residentBytes, resident)
        XCTAssertEqual(dump(layer), before)
    }

    func testRGBA8Layer() {
        let layer = TiledLayer(name: "8", width: 1024, height: 512, format: .rgba8)
        layer.fill([0.5, 0.25, 0.1, 1])
        let p = layer.pixel(x: 10, y: 10)
        XCTAssertEqual(p.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(p.y, 0.25, accuracy: 0.01)
        XCTAssertEqual(p.w, 1)
        XCTAssertEqual(layer.residentBytes, layer.storedTiles.count * 4)
    }
}
