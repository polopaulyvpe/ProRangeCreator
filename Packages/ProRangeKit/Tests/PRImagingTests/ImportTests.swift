import Foundation
import PRCore
@testable import PRImaging
import PRStorage
import simd
import XCTest

/// Phase 7, lot B : décodage et conversion des imports (panorama, cubemap).
final class ImportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("primp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func paintedLayer(width: Int = 512, height: Int = 256) -> TiledLayer {
        let layer = TiledLayer(name: "src", width: width, height: height)
        layer.stamp(SphericalDab(center: [1, 0, 0], radius: 0.5, hardness: 0.3, color: [2.5, 0.4, 0.1, 1]))
        layer.stamp(SphericalDab(center: [0, 0, -1], radius: 0.6, hardness: 0.5, color: [0.1, 0.7, 0.9, 1]))
        layer.stamp(SphericalDab(center: [0, 1, 0], radius: 0.7, hardness: 0.4, color: [0.9, 0.9, 0.2, 1]))
        layer.stamp(SphericalDab(center: [-0.5, -0.6, 0.6], radius: 0.5, hardness: 0.2, color: [0.6, 0.1, 0.8, 1]))
        return layer
    }

    private func psnr(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>], peak: Float = 1) -> Double {
        PanoramaExporter.psnr(a.map { SIMD3($0.x, $0.y, $0.z) }, b.map { SIMD3($0.x, $0.y, $0.z) }, peak: peak)
    }

    func testDecodePNGAndEXR() throws {
        let layer = paintedLayer()
        let png = directory.appendingPathComponent("a.png")
        try PanoramaExporter.export(layer, as: .png(bitDepth: 16, includeAlpha: false), to: png)
        let decoded = try ImageDecoder.decode(png)
        XCTAssertEqual(decoded.width, 512)
        let expected = LayerRowSource(layer: layer, paper: [1, 1, 1]).rows(0, 256).map { p -> SIMD4<Float> in
            let c = simd_clamp(SIMD3(p.x, p.y, p.z), .zero, .one) // écrêtage d'affichage, puis sRGB aller-retour
            return SIMD4(c.x, c.y, c.z, 1)
        }
        XCTAssertGreaterThan(psnr(decoded.pixels, expected), 50, "PNG relu en linéaire")

        let exr = directory.appendingPathComponent("a.exr")
        try PanoramaExporter.export(layer, as: .exr(.float, .zip, includeAlpha: true), options: PanoramaExportOptions(paper: nil), to: exr)
        let hdr = try ImageDecoder.decode(exr)
        let reference = LayerRowSource(layer: layer, paper: nil).rows(0, 256)
        XCTAssertGreaterThan(psnr(hdr.pixels, reference, peak: 2.5), 60, "EXR relu avec son HDR")

        let radiance = directory.appendingPathComponent("a.hdr")
        try PanoramaExporter.export(layer, as: .hdr, to: radiance)
        XCTAssertEqual(try ImageDecoder.decode(radiance).height, 256)
        XCTAssertThrowsError(try ImageDecoder.decode(data: Data([1, 2, 3])))
    }

    func testEquirectangularImportIdentityAndResampling() throws {
        let layer = paintedLayer()
        let image = ImportedImage(width: 512, height: 256, pixels: layer.allPixels())
        let same = TiledLayer(name: "a", width: 512, height: 256)
        same.beginOperation()
        PanoramaImport.equirectangular(image, into: same, fit: .crop)
        XCTAssertFalse(same.endOperation().isEmpty, "import annulable")
        XCTAssertGreaterThan(psnr(same.allPixels(), image.pixels, peak: 2.5), 60, "même taille : identique")

        // Réduction 2× : moyenne de blocs 2 × 2.
        let big = TiledLayer(name: "b", width: 1024, height: 512)
        big.fill([0.2, 0.4, 0.6, 1])
        let half = TiledLayer(name: "h", width: 512, height: 256)
        PanoramaImport.equirectangular(ImportedImage(width: 1024, height: 512, pixels: big.allPixels()), into: half, fit: .stretch)
        XCTAssertLessThan(simd_reduce_max(simd_abs(half.pixel(x: 100, y: 100) - SIMD4<Float>(0.2, 0.4, 0.6, 1))), 2e-3)

        // Lacet : un quart de tour décale d'un quart de largeur.
        let turned = TiledLayer(name: "t", width: 512, height: 256)
        PanoramaImport.equirectangular(image, into: turned, fit: .crop, yawDegrees: 90)
        XCTAssertLessThan(simd_reduce_max(simd_abs(turned.pixel(x: 128 + 128, y: 128) - layer.pixel(x: 128, y: 128))), 2e-3)
    }

    func testCropAndPadNonPanoramicImages() {
        // Image carrée : moitié haute rouge, moitié basse bleue.
        let size = 64
        var pixels = [SIMD4<Float>](repeating: [0, 0, 1, 1], count: size * size)
        for i in 0..<(size * size / 2) { pixels[i] = [1, 0, 0, 1] }
        let square = ImportedImage(width: size, height: size, pixels: pixels)

        let padded = TiledLayer(name: "p", width: 512, height: 256)
        PanoramaImport.equirectangular(square, into: padded, fit: .pad)
        XCTAssertEqual(padded.pixel(x: 10, y: 128).w, 0, accuracy: 1e-6, "marge transparente à gauche")
        XCTAssertEqual(padded.pixel(x: 256, y: 60).x, 1, accuracy: 1e-3, "image au centre")
        XCTAssertEqual(padded.pixel(x: 256, y: 200).z, 1, accuracy: 1e-3)

        let cropped = TiledLayer(name: "c", width: 512, height: 256)
        PanoramaImport.equirectangular(square, into: cropped, fit: .crop)
        XCTAssertEqual(cropped.pixel(x: 10, y: 10).w, 1, accuracy: 1e-6, "recadré : plein cadre")
        XCTAssertEqual(cropped.pixel(x: 10, y: 10).x, 1, accuracy: 1e-3, "bande centrale : le haut est rouge")
        XCTAssertEqual(cropped.pixel(x: 10, y: 250).z, 1, accuracy: 1e-3)
    }

    func testCubemapRoundTrip() throws {
        let layer = paintedLayer()
        let faces = try PanoramaExporter.export(layer, as: .exr(.float, .none, includeAlpha: true),
                                                options: PanoramaExportOptions(paper: nil, layout: .cubeFaces),
                                                to: directory.appendingPathComponent("f.exr"))
        let decoded = try faces.map { try ImageDecoder.decode($0) }
        let back = TiledLayer(name: "back", width: 512, height: 256)
        PanoramaImport.cubemap(decoded, into: back)
        XCTAssertGreaterThan(psnr(back.allPixels(), layer.allPixels(), peak: 2.5), 30, "équirect → cubemap → équirect")

        // Une croix relue donne les mêmes faces que les six fichiers.
        let crossURL = try XCTUnwrap(PanoramaExporter.export(layer, as: .exr(.float, .none, includeAlpha: true),
                                                             options: PanoramaExportOptions(paper: nil, layout: .cubeCross),
                                                             to: directory.appendingPathComponent("x.exr")).first)
        let cross = try ImageDecoder.decode(crossURL)
        XCTAssertEqual(CubemapSourceLayout.detect(width: cross.width, height: cross.height), .horizontalCross)
        let split = PanoramaImport.faces(from: cross, layout: .horizontalCross)
        for (a, b) in zip(split, decoded) { XCTAssertEqual(a.pixels, b.pixels) }

        let strip = PanoramaImport.faces(from: ImportedImage(width: 6 * 4, height: 4, pixels: (0..<(24 * 4)).map { i in
            SIMD4<Float>(Float(i % 24 / 4), 0, 0, 1)
        }), layout: .horizontalStrip)
        XCTAssertEqual(strip.map { $0.pixels[0].x }, [0, 1, 2, 3, 4, 5], "bande : ordre +X −X +Y −Y +Z −Z")
        XCTAssertEqual(CubemapSourceLayout.detect(width: 300, height: 400), .verticalCross)
        XCTAssertNil(CubemapSourceLayout.detect(width: 512, height: 256))
    }
}
