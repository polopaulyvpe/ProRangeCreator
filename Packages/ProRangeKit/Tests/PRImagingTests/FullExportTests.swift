import CoreGraphics
import Foundation
import ImageIO
import PRCore
@testable import PRImaging
import PRStorage
import simd
import XCTest

/// Phase 7, lot A : PNG, JPG, TIFF relus par ImageIO ; orientation ; cubemap ; lot de résolutions.
final class FullExportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("prexp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Calque 1024 × 512 : une tache de couleur différente face à chaque axe, et du HDR face à +X.
    private func axesLayer() -> TiledLayer {
        let layer = TiledLayer(name: "axes", width: 1024, height: 512)
        let dabs: [(Vec3, SIMD4<Float>)] = [
            ([1, 0, 0], [3, 0.2, 0.1, 1]), ([-1, 0, 0], [0.1, 0.8, 0.1, 1]),
            ([0, 1, 0], [0.1, 0.1, 0.9, 1]), ([0, -1, 0], [0.9, 0.9, 0.1, 1]),
            ([0, 0, 1], [0.9, 0.1, 0.9, 1]), ([0, 0, -1], [0.1, 0.9, 0.9, 1]),
        ]
        for (center, color) in dabs { layer.stamp(SphericalDab(center: center, radius: 0.3, hardness: 1, color: color)) }
        return layer
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Pixels tels que stockés dans le fichier (sans gestion de couleur), en flottants : entiers ramenés à [0, 1],
    /// alpha prémultiplié par ImageIO rendu droit.
    private func rawPixels(_ url: URL) throws -> (width: Int, height: Int, pixels: [SIMD4<Float>], bits: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "ImageIO ne reconnaît pas \(url.lastPathComponent)")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), "ImageIO ne décode pas \(url.lastPathComponent)")
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let bytes = [UInt8](data)
        let bpc = image.bitsPerComponent
        let components = image.bitsPerPixel / bpc
        let info = image.bitmapInfo
        let isFloat = info.contains(.floatComponents)
        let order = info.intersection(.byteOrderMask)
        let little = order == .byteOrder16Little || order == .byteOrder32Little
        let alpha = image.alphaInfo
        func value(_ offset: Int) -> Float {
            switch bpc {
            case 8:
                return Float(bytes[offset]) / 255
            case 16:
                let raw = little ? UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8 : UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
                return isFloat ? Float(Float16(bitPattern: raw)) : Float(raw) / 65535
            default:
                var raw: UInt32 = 0
                for k in 0..<4 {
                    let byte = UInt32(bytes[offset + k])
                    raw |= little ? byte << (8 * k) : byte << (8 * (3 - k))
                }
                return isFloat ? Float(bitPattern: raw) : Float(raw) / Float(UInt32.max)
            }
        }
        var pixels: [SIMD4<Float>] = []
        pixels.reserveCapacity(image.width * image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let base = y * image.bytesPerRow + x * components * bpc / 8
                var c = (0..<components).map { value(base + $0 * bpc / 8) }
                var a: Float = 1
                switch alpha {
                case .premultipliedFirst, .first:
                    a = c.removeFirst()
                case .premultipliedLast, .last:
                    a = c.removeLast()
                case .noneSkipFirst:
                    c.removeFirst()
                case .noneSkipLast:
                    c.removeLast()
                default:
                    break
                }
                if (alpha == .premultipliedFirst || alpha == .premultipliedLast), a > 0, !isFloat { c = c.map { $0 / a } }
                while c.count < 3 { c.append(c.last ?? 0) }
                pixels.append(SIMD4<Float>(c[0], c[1], c[2], a))
            }
        }
        return (image.width, image.height, pixels, bpc)
    }

    func testPNGRoundTripThroughImageIO() throws {
        let layer = axesLayer()
        let display = DisplayTransform(exposure: -1, toneMapping: .aces)
        let source = LayerRowSource(layer: layer, paper: [1, 1, 1])
        let expected = source.rows(0, 512).map { display.encode($0) }
        for bits in [8, 16] {
            let target = url("p\(bits).png")
            try PanoramaExporter.export(layer, as: .png(bitDepth: bits, includeAlpha: false),
                                        options: PanoramaExportOptions(display: display), to: target)
            let back = try rawPixels(target)
            XCTAssertEqual(back.width, 1024)
            XCTAssertEqual(back.bits, bits)
            let tolerance: Float = bits == 8 ? 0.6 / 255 : 2 / 65535
            var worst: Float = 0
            for i in expected.indices {
                let d = simd_abs(back.pixels[i] - expected[i])
                worst = max(worst, max(d.x, d.y, d.z))
            }
            XCTAssertLessThanOrEqual(worst, tolerance, "PNG \(bits) bits")
        }

        // Transparent : alpha conservé, couleur droite.
        let transparent = url("alpha.png")
        try PanoramaExporter.export(layer, as: .png(bitDepth: 8, includeAlpha: true), options: PanoramaExportOptions(paper: nil), to: transparent)
        let back = try rawPixels(transparent)
        let empty = Equirect.pixel(from: Equirect.direction(latitude: 0.5, longitude: .pi / 4), width: 1024, height: 512)
        XCTAssertEqual(back.pixels[Int(empty.y) * 1024 + Int(empty.x)].w, 0, accuracy: 1e-6, "zone vide transparente")
        let center = back.pixels[256 * 1024 + 512] // face à -Z : cyan
        XCTAssertEqual(center.w, 1, accuracy: 1e-3)
        XCTAssertEqual(center.y, ColorTransfer.toEncoded(0.9), accuracy: 2 / 255)
    }

    func testTIFFFloatRoundTripThroughImageIO() throws {
        let layer = axesLayer()
        let reference = LayerRowSource(layer: layer, paper: nil).rows(0, 512)
        for bits in [16, 32] {
            let target = url("t\(bits).tif")
            try PanoramaExporter.export(layer, as: .tiff(bitsPerSample: bits, includeAlpha: true),
                                        options: PanoramaExportOptions(paper: nil), to: target)
            let back = try rawPixels(target)
            XCTAssertEqual(back.width, 1024)
            XCTAssertEqual(back.height, 512)
            let hdr = Equirect.pixel(from: [1, 0, 0], width: 1024, height: 512)
            let i = Int(hdr.y) * 1024 + Int(hdr.x)
            XCTAssertEqual(back.pixels[i].x, reference[i].x, accuracy: bits == 16 ? 3e-3 : 1e-6, "HDR conservé (\(bits) bits)")
            var mismatches = 0
            for j in reference.indices where simd_reduce_max(simd_abs(back.pixels[j] - reference[j])) > (bits == 16 ? 3e-3 : 1e-6) {
                mismatches += 1
            }
            XCTAssertEqual(mismatches, 0, "TIFF \(bits) bits identique à la source")
        }
    }

    func testJPEGIsReadable() throws {
        let layer = axesLayer()
        let target = url("j.jpg")
        try PanoramaExporter.export(layer, as: .jpeg(quality: 0.9), to: target)
        let back = try rawPixels(target)
        XCTAssertEqual(back.width, 1024)
        let expected = LayerRowSource(layer: layer, paper: [1, 1, 1]).rows(0, 512).map { DisplayTransform().encode($0) }
        let psnr = PanoramaExporter.psnr(back.pixels.map { SIMD3($0.x, $0.y, $0.z) }, expected.map { SIMD3($0.x, $0.y, $0.z) })
        XCTAssertGreaterThan(psnr, 30)
    }

    func testOrientationShiftsAndMirrorsLosslessly() throws {
        let layer = axesLayer()
        func export(_ orientation: ExportOrientation, _ name: String) throws -> [SIMD4<Float>] {
            let target = url(name)
            try PanoramaExporter.export(layer, as: .exr(.float, .zip, includeAlpha: true),
                                        options: PanoramaExportOptions(paper: nil, orientation: orientation), to: target)
            return try EXRReader.read(target).pixels
        }
        let generic = try export(.identity, "g.exr")
        let blender = try export(OrientationPreset.blender.orientation, "b.exr")
        let mirrored = try export(ExportOrientation(flipHorizontal: true), "m.exr")
        for y in stride(from: 0, to: 512, by: 37) {
            for x in stride(from: 0, to: 1024, by: 29) {
                XCTAssertEqual(blender[y * 1024 + x], generic[y * 1024 + (x + 256) % 1024], "lacet −90° : décalage d'un quart")
                XCTAssertEqual(mirrored[y * 1024 + x], generic[y * 1024 + 1023 - x], "miroir")
            }
        }
        // Le devant de l'app (−Z, cyan) arrive en u = 0,25 avec Blender, là où Blender met sa vue de face (+Y).
        XCTAssertEqual(blender[256 * 1024 + 256].y, 0.9, accuracy: 1e-3)
    }

    func testCubemapFacesCrossAndStrip() throws {
        for d in [Vec3(0.3, -0.5, 0.8), Vec3(-0.9, 0.2, 0.1), Vec3(0.1, 0.95, -0.2), Vec3(0.2, -0.1, -0.97)] {
            let n = simd_normalize(d)
            let (face, a, b) = CubemapFace.locate(n)
            let back = simd_normalize(face.direction(a: a, b: b))
            XCTAssertLessThan(simd_distance(back, n), 1e-12, "face \(face) aller-retour")
        }

        let layer = axesLayer()
        let colors: [CubemapFace: SIMD3<Float>] = [.px: [3, 0.2, 0.1], .nx: [0.1, 0.8, 0.1], .py: [0.1, 0.1, 0.9],
                                                   .ny: [0.9, 0.9, 0.1], .pz: [0.9, 0.1, 0.9], .nz: [0.1, 0.9, 0.9]]
        let faces = try PanoramaExporter.export(layer, as: .exr(.float, .none, includeAlpha: true),
                                                options: PanoramaExportOptions(paper: nil, layout: .cubeFaces), to: url("c.exr"))
        XCTAssertEqual(faces.map(\.lastPathComponent), ["c_px.exr", "c_nx.exr", "c_py.exr", "c_ny.exr", "c_pz.exr", "c_nz.exr"])
        for (face, file) in zip(CubemapFace.allCases, faces) {
            let image = try EXRReader.read(file)
            XCTAssertEqual(image.width, 256)
            XCTAssertEqual(image.height, 256)
            let c = image.pixels[128 * 256 + 128]
            XCTAssertLessThan(simd_distance(SIMD3(c.x, c.y, c.z), colors[face]!), 0.02, "centre de la face \(face)")
        }

        let cross = try EXRReader.read(try XCTUnwrap(PanoramaExporter.export(
            layer, as: .exr(.half, .zip, includeAlpha: true),
            options: PanoramaExportOptions(paper: nil, layout: .cubeCross), to: url("x.exr")).first))
        XCTAssertEqual(cross.width, 1024)
        XCTAssertEqual(cross.height, 768)
        func crossCenter(_ column: Int, _ row: Int) -> SIMD4<Float> { cross.pixels[(row * 256 + 128) * 1024 + column * 256 + 128] }
        XCTAssertLessThan(simd_distance(SIMD3(crossCenter(1, 0).x, crossCenter(1, 0).y, crossCenter(1, 0).z), colors[.py]!), 0.02)
        XCTAssertLessThan(simd_distance(SIMD3(crossCenter(3, 1).x, crossCenter(3, 1).y, crossCenter(3, 1).z), colors[.nz]!), 0.02)
        XCTAssertEqual(crossCenter(0, 0).w, 0, "case vide transparente")

        let strip = try EXRReader.read(try XCTUnwrap(PanoramaExporter.export(
            layer, as: .exr(.half, .zip, includeAlpha: true),
            options: PanoramaExportOptions(paper: nil, layout: .cubeStrip), to: url("s.exr")).first))
        XCTAssertEqual(strip.width, 1536)
        XCTAssertEqual(strip.height, 256)
        let fifth = strip.pixels[128 * 1536 + 4 * 256 + 128]
        XCTAssertLessThan(simd_distance(SIMD3(fifth.x, fifth.y, fifth.z), colors[.pz]!), 0.02, "5e case = +Z")
    }

    func testBatchAndCancellation() throws {
        let stack = LayerStack(width: 1024, height: 512)
        stack.items[0].layer!.stamp(SphericalDab(center: [0, 0, -1], radius: 0.4, hardness: 1, color: [1, 0, 0, 1]))
        let urls = try PanoramaExporter.exportBatch(stack, as: .hdr, downscales: [1, 2], to: url("lot.hdr"))
        XCTAssertEqual(urls.map(\.lastPathComponent), ["lot_1K.hdr", "lot_512.hdr"])
        XCTAssertEqual(try RadianceReader.read(urls[1]).width, 512)

        for format: PanoramaFormat in [.png(bitDepth: 8, includeAlpha: true), .tiff(bitsPerSample: 32, includeAlpha: false), .jpeg(quality: 0.8)] {
            let target = url("annule.\(format.fileExtension)")
            XCTAssertThrowsError(try PanoramaExporter.export(stack, as: format, to: target) { _ in false })
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains("annule") }
            XCTAssertEqual(leftovers, [], "\(format) : aucun fichier après annulation")
        }
    }

    func testUpscaledExport() throws {
        let layer = axesLayer()
        let target = url("x2.exr")
        try PanoramaExporter.export(layer, as: .exr(.float, .zip, includeAlpha: true),
                                    options: PanoramaExportOptions(paper: nil, upscale: 2), to: target)
        let big = try EXRReader.read(target)
        XCTAssertEqual(big.width, 2048)
        XCTAssertEqual(big.height, 1024)
        let source = LayerRowSource(layer: layer, paper: nil).rows(0, 512)
        // Centre d'une tache : même couleur ; agrandi = interpolation des voisins de la source.
        let c = big.pixels[512 * 2048 + 1024]
        XCTAssertLessThan(simd_distance(c, source[256 * 1024 + 512]), 0.02)
        XCTAssertLessThan(simd_distance(big.pixels[520 * 2048 + 1030], source[260 * 1024 + 515]), 0.02, "intérieur uniforme")
        let empty = Equirect.pixel(from: Equirect.direction(latitude: 0.5, longitude: .pi / 4), width: 2048, height: 1024)
        XCTAssertEqual(big.pixels[Int(empty.y) * 2048 + Int(empty.x)].w, 0, accuracy: 1e-6, "vide reste vide")
    }

    func testToneMappingCurves() {
        let gray = SIMD3<Float>(repeating: 0.18)
        for curve in ToneMapping.allCases {
            let mapped = curve.apply(gray)
            XCTAssertGreaterThan(mapped.x, 0.02, curve.label)
            XCTAssertLessThan(mapped.x, 0.6, curve.label)
            XCTAssertLessThanOrEqual(curve.apply(SIMD3(repeating: 100)).x, 1, curve.label)
        }
        XCTAssertEqual(DisplayTransform().encode([0.5, 0.5, 0.5, 1]).x, ColorTransfer.toEncoded(0.5), accuracy: 1e-6)
        XCTAssertEqual(DisplayTransform(exposure: 1).encode([0.25, 0.25, 0.25, 0.5]).x, ColorTransfer.toEncoded(1), accuracy: 1e-6,
                       "dé-prémultiplié puis exposé")
    }
}
