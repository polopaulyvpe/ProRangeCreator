import CoreGraphics
import Foundation
import ImageIO
import PRCore
@testable import PRImaging
import PRStorage
import XCTest

final class ExportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("primg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Image de test : dégradé lisse avec des valeurs HDR, moitié gauche fixe pour la relecture par ImageIO.
    private func syntheticRows(width: Int) -> RowProvider {
        { y, count in
            var out: [SIMD4<Float>] = []
            for line in y..<(y + count) {
                for x in 0..<width {
                    if x < width / 2 {
                        out.append([0.25, 0.5, 1.0, 1])
                    } else {
                        let t = Float(x) / Float(width)
                        out.append([2 + t * 6, Float(line) / 64, t * 0.1, 1])
                    }
                }
            }
            return out
        }
    }

    func testEXRRoundTripAllVariants() throws {
        let width = 64, height = 40 // 40 lignes : dernier bloc ZIP incomplet
        let rows = syntheticRows(width: width)
        let reference = try rows(0, height)
        for pixelType in EXRPixelType.allCases {
            for compression in EXRCompression.allCases {
                for alpha in [false, true] {
                    let url = directory.appendingPathComponent("t-\(pixelType)-\(compression)-\(alpha).exr")
                    try EXRWriter.write(to: url, width: width, height: height, pixelType: pixelType, compression: compression,
                                        includeAlpha: alpha, bandHeight: 16, rows: rows)
                    let image = try EXRReader.read(url)
                    XCTAssertEqual(image.width, width)
                    XCTAssertEqual(image.height, height)
                    XCTAssertEqual(image.channels, alpha ? ["A", "B", "G", "R"] : ["B", "G", "R"])
                    for i in reference.indices {
                        let expected = pixelType == .half
                            ? SIMD4<Float>(Float(Float16(reference[i].x)), Float(Float16(reference[i].y)), Float(Float16(reference[i].z)), 1)
                            : reference[i]
                        XCTAssertEqual(image.pixels[i], expected, "\(pixelType) \(compression) pixel \(i)")
                        if image.pixels[i] != expected { break }
                    }
                }
            }
        }
    }

    func testZipCompressesSmoothImages() throws {
        let rows = syntheticRows(width: 256)
        let none = directory.appendingPathComponent("none.exr")
        let zip = directory.appendingPathComponent("zip.exr")
        try EXRWriter.write(to: none, width: 256, height: 128, pixelType: .half, compression: .none, includeAlpha: false, rows: rows)
        try EXRWriter.write(to: zip, width: 256, height: 128, pixelType: .half, compression: .zip, includeAlpha: false, rows: rows)
        let noneSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: none.path)[.size] as? Int)
        let zipSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int)
        XCTAssertLessThan(zipSize, noneSize / 2)
    }

    /// Un décodeur indépendant (ImageIO d'Apple) lit nos EXR : protège contre une erreur symétrique écrivain/lecteur.
    func testImageIOReadsOurEXR() throws {
        let width = 64, height = 32
        for compression in EXRCompression.allCases {
            for pixelType in EXRPixelType.allCases {
                let url = directory.appendingPathComponent("io-\(compression)-\(pixelType).exr")
                try EXRWriter.write(to: url, width: width, height: height, pixelType: pixelType, compression: compression,
                                    includeAlpha: true, bandHeight: 16, rows: syntheticRows(width: width))
                let pixels = try decodeWithImageIO(url, width: width, height: height)
                let left = pixels[10 * width + 5]
                XCTAssertEqual(left.x, 0.25, accuracy: 0.03, "\(compression) \(pixelType)")
                XCTAssertEqual(left.y, 0.5, accuracy: 0.03, "\(compression) \(pixelType)")
                XCTAssertEqual(left.z, 1.0, accuracy: 0.03, "\(compression) \(pixelType)")
                XCTAssertGreaterThan(pixels[10 * width + 60].x, 0.99, "valeur HDR conservée (ou au moins écrêtée à 1)")
            }
        }
    }

    func testRadianceRoundTrip() throws {
        for width in [4, 64, 300] { // 4 : pixels bruts ; ≥ 8 : RLE
            let height = 20
            let rows = syntheticRows(width: width)
            let url = directory.appendingPathComponent("t-\(width).hdr")
            try RadianceWriter.write(to: url, width: width, height: height, bandHeight: 7, rows: rows)
            let image = try RadianceReader.read(url)
            XCTAssertEqual(image.width, width)
            XCTAssertEqual(image.height, height)
            let reference = try rows(0, height)
            for i in reference.indices {
                let ref = SIMD3<Float>(reference[i].x, reference[i].y, reference[i].z)
                let peak = max(ref.x, ref.y, ref.z)
                let diff: SIMD3<Float> = image.pixels[i] - ref
                let error = max(abs(diff.x), abs(diff.y), abs(diff.z))
                XCTAssertLessThanOrEqual(error, peak / 128 + 1e-6, "pixel \(i) : \(image.pixels[i]) ≠ \(ref)")
                if error > peak / 128 + 1e-6 { break }
            }
        }
    }

    func testRLEHandlesRunsAndLiterals() {
        let data: [UInt8] = [1, 2, 3] + Array(repeating: 9, count: 200) + [4, 4] + Array(0...150).map { UInt8($0) }
        let encoded = RadianceWriter.rle(data)
        XCTAssertLessThan(encoded.count, data.count)
        var decoded: [UInt8] = []
        var i = 0
        while i < encoded.count {
            let count = Int(encoded[i])
            if count > 128 {
                decoded += Array(repeating: encoded[i + 1], count: count - 128)
                i += 2
            } else {
                decoded += encoded[(i + 1)..<(i + 1 + count)]
                i += 1 + count
            }
        }
        XCTAssertEqual(decoded, data)
    }

    func testImageIOReadsOurRadiance() throws {
        let types = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        guard types.contains("public.radiance") else { throw XCTSkip("ImageIO ne lit pas le Radiance ici") }
        let url = directory.appendingPathComponent("io.hdr")
        try RadianceWriter.write(to: url, width: 64, height: 32, rows: syntheticRows(width: 64))
        let pixels = try decodeWithImageIO(url, width: 64, height: 32)
        XCTAssertEqual(pixels[10 * 64 + 5].y, 0.5, accuracy: 0.03)
    }

    func testZlibAndPredictorRoundTrip() throws {
        XCTAssertEqual(Zlib.adler32(Array("Wikipedia".utf8)), 0x11E6_0398)
        let raw = (0..<5000).map { UInt8(truncatingIfNeeded: $0 / 7) }
        XCTAssertEqual(EXRWriter.zipPostprocess(EXRWriter.zipPreprocess(raw)), raw)
        let compressed = try XCTUnwrap(Zlib.compress(raw))
        XCTAssertEqual(try Zlib.decompress(compressed, expectedSize: raw.count), raw)
        XCTAssertNil(Zlib.compress((0..<64).map { _ in UInt8.random(in: 0...255) }), "pas de gain : stocké brut")
    }

    // MARK: - Export d'un calque

    private func paintedLayer() -> TiledLayer {
        let layer = TiledLayer(name: "t", width: 1024, height: 512)
        layer.stamp(SphericalDab(center: [0, 0, -1], radius: 0.4, hardness: 0.6, color: [3, 1.5, 0.2, 1]))
        layer.stamp(SphericalDab(center: [0, 1, 0], radius: 0.3, hardness: 1, color: [0.1, 0.2, 0.9, 0.7]))
        layer.stamp(SphericalDab(center: Equirect.direction(latitude: -0.2, longitude: .pi), radius: 0.25, hardness: 0.9, color: [0.9, 0.9, 0.1, 1]))
        return layer
    }

    func testLayerExportMatchesSourceAndIsStreamed() throws {
        let layer = paintedLayer()
        let source = LayerRowSource(layer: layer, paper: [1, 1, 1])
        let reference = source.rows(0, source.height)
        let url = directory.appendingPathComponent("layer.exr")
        var bands = 0
        try PanoramaExporter.export(layer, as: .exr(.float, .zip, includeAlpha: false), to: url) { _ in
            bands += 1
            return true
        }
        XCTAssertEqual(bands, 2, "512 lignes en bandes de 256")
        let image = try EXRReader.read(url)
        XCTAssertEqual(image.pixels, reference)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".layer.exr.partial").path))

        let hdr = directory.appendingPathComponent("layer.hdr")
        try PanoramaExporter.export(layer, as: .hdr, to: hdr)
        let back = try RadianceReader.read(hdr)
        let rgbReference = reference.map { SIMD3<Float>($0.x, $0.y, $0.z) }
        XCTAssertGreaterThan(PanoramaExporter.psnr(back.pixels, rgbReference, peak: 3), 45)
    }

    func testDownscaledAndTransparentExport() throws {
        let layer = paintedLayer()
        let url = directory.appendingPathComponent("small.exr")
        try PanoramaExporter.export(layer, as: .exr(.half, .zip, includeAlpha: true),
                                    options: PanoramaExportOptions(downscale: 4, paper: nil), to: url)
        let image = try EXRReader.read(url)
        XCTAssertEqual(image.width, 256)
        XCTAssertEqual(image.height, 128)
        XCTAssertEqual(image.pixels[40 * 256 + 10].w, 0, "fond transparent hors peinture")
        XCTAssertGreaterThan(image.pixels[64 * 256 + 128].x, 1, "centre du dab HDR, face à -Z")
    }

    func testCancelledExportLeavesNoFile() {
        let layer = paintedLayer()
        let url = directory.appendingPathComponent("cancel.exr")
        XCTAssertThrowsError(try PanoramaExporter.export(layer, as: .exr(.half, .none, includeAlpha: false), to: url) { _ in false }) {
            XCTAssertEqual($0 as? ExportError, .cancelled)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    // MARK: - ImageIO

    private func decodeWithImageIO(_ url: URL, width: Int, height: Int) throws -> [SIMD4<Float>] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "ImageIO ne reconnaît pas \(url.lastPathComponent)")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), "ImageIO ne décode pas \(url.lastPathComponent)")
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)
        var pixels = [SIMD4<Float>](repeating: .zero, count: width * height)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 32,
                                    bytesPerRow: width * 16, space: space, bitmapInfo: info)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }
}
