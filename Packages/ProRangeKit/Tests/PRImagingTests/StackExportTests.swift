import Foundation
import PRCore
import PRImaging
import PRStorage
import XCTest

final class StackExportTests: XCTestCase {
    func testStackExportMatchesCompositor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("prstackexp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stack = LayerStack(width: 1024, height: 512)
        stack.items[0].layer!.stamp(SphericalDab(center: [0, 0, -1], radius: 0.5, hardness: 0.5, color: [0.9, 0.8, 0.2, 1]))
        let top = stack.addLayer()!
        top.layer!.stamp(SphericalDab(center: [0, 0, -1], radius: 0.3, hardness: 1, color: [0.2, 0.4, 0.9, 1]))
        stack.update(top.id) { $0.blendMode = .multiply }

        let url = directory.appendingPathComponent("pile.exr")
        try PanoramaExporter.export(stack, as: .exr(.float, .zip, includeAlpha: false), to: url)
        let image = try EXRReader.read(url)
        let center = image.pixels[256 * 1024 + 512]
        let expected = LayerCompositor.compositeTile(TileCoord(x: 2, y: 1), stack: stack, paper: [1, 1, 1], space: .perceptual)[0]
        XCTAssertEqual(center, expected)
        XCTAssertLessThan(center.z, 0.9, "le Produit assombrit")
        XCTAssertEqual(image.pixels[0], [1, 1, 1, 1], "papier hors peinture")
    }
}
