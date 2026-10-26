import AVFoundation
import Compression
import Foundation
import PRCore
@testable import PRImaging
import XCTest

/// Faux pinceau Procreate : un objet archivé par NSKeyedArchiver avec des clés plates, comme `SilicaBrush`.
private final class FakeBrush: NSObject, NSCoding {
    override init() {}
    required init?(coder: NSCoder) { nil }

    func encode(with coder: NSCoder) {
        coder.encode("Craie sèche", forKey: "name")
        coder.encode(0.5, forKey: "maxSize")
        coder.encode(0.2, forKey: "minSize")
        coder.encode(0.8, forKey: "maxOpacity")
        coder.encode(0.1, forKey: "plotSpacing")
        coder.encode(0.25, forKey: "shapeRotation")
        coder.encode(1.0, forKey: "dynamicsPressureSize")
        coder.encode(0.6, forKey: "textureDepth")
        coder.encode(3.0, forKey: "wetMix")
    }
}

final class BrushAndTimelapseTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("prbrush-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// ZIP minimal : entrées stockées, ou compressées en deflate si `deflate`.
    private func zip(_ files: [(String, [UInt8])], deflate: Bool) -> Data {
        var out: [UInt8] = []
        var central: [UInt8] = []
        func le16(_ v: Int, _ b: inout [UInt8]) { b += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: Int, _ b: inout [UInt8]) { for k in 0..<4 { b.append(UInt8((v >> (8 * k)) & 0xFF)) } }
        for (name, content) in files {
            var payload = content
            var method = 0
            if deflate, !content.isEmpty {
                var buffer = [UInt8](repeating: 0, count: content.count + 1024)
                let n = compression_encode_buffer(&buffer, buffer.count, content, content.count, nil, COMPRESSION_ZLIB)
                payload = Array(buffer[0..<n])
                method = 8
            }
            let offset = out.count
            let nameBytes = Array(name.utf8)
            le32(0x0403_4B50, &out); le16(20, &out); le16(0, &out); le16(method, &out); le32(0, &out); le32(0, &out)
            le32(payload.count, &out); le32(content.count, &out); le16(nameBytes.count, &out); le16(0, &out)
            out += nameBytes + payload
            le32(0x0201_4B50, &central); le16(20, &central); le16(20, &central); le16(0, &central); le16(method, &central)
            le32(0, &central); le32(0, &central); le32(payload.count, &central); le32(content.count, &central)
            le16(nameBytes.count, &central); le16(0, &central); le16(0, &central); le16(0, &central); le16(0, &central); le32(0, &central)
            le32(offset, &central)
            central += nameBytes
        }
        let centralOffset = out.count
        out += central
        le32(0x0605_4B50, &out); le16(0, &out); le16(0, &out); le16(files.count, &out); le16(files.count, &out)
        le32(central.count, &out); le32(centralOffset, &out); le16(0, &out)
        return Data(out)
    }

    /// PNG 32 × 32 en niveaux de gris (disque blanc sur noir), écrit par notre encodeur.
    private func shapePNG() throws -> [UInt8] {
        let url = directory.appendingPathComponent("shape-\(UUID().uuidString).png")
        try PNGWriter.write(to: url, width: 32, height: 32, bitDepth: 8, includeAlpha: false, rows: { y, count in
            (y..<(y + count)).flatMap { row in
                (0..<32).map { x -> SIMD4<Float> in
                    let dx = Float(x) - 15.5, dy = Float(row) - 15.5
                    return dx * dx + dy * dy < 144 ? [1, 1, 1, 1] : [0, 0, 0, 1]
                }
            }
        })
        return [UInt8](try Data(contentsOf: url))
    }

    func testProcreateBrushImportMapsWhatItCan() throws {
        let archive = try NSKeyedArchiver.archivedData(withRootObject: FakeBrush(), requiringSecureCoding: false)
        let png = try shapePNG()
        for deflate in [false, true] {
            let data = zip([("Brush.archive", [UInt8](archive)), ("Shape.png", png), ("QuickLook/Thumbnail.png", png)], deflate: deflate)
            let presets = try ProcreateBrushImport.read(data: data, fallbackName: "fichier")
            XCTAssertEqual(presets.count, 1)
            let preset = try XCTUnwrap(presets.first)
            XCTAssertEqual(preset.name, "Craie sèche", "nom lu via la référence de l'archive")
            XCTAssertEqual(preset.settings.opacity, 0.8, accuracy: 1e-9)
            XCTAssertEqual(preset.settings.spacing, 0.2, accuracy: 1e-9, "fraction du diamètre → fraction du rayon")
            XCTAssertEqual(preset.settings.shapeRotationDegrees, 90, accuracy: 1e-9)
            XCTAssertEqual(preset.settings.grainDepth, 0.6, accuracy: 1e-9)
            XCTAssertTrue(preset.settings.pressureAffectsSize)
            let shape = try XCTUnwrap(preset.settings.shape)
            XCTAssertEqual(shape.size, 32)
            XCTAssertGreaterThan(shape.values[16 * 32 + 16], 0.9, "disque blanc au centre")
            XCTAssertLessThan(shape.values[0], 0.1)
            XCTAssertNil(preset.settings.grain)
            XCTAssertTrue(preset.ignored.contains("wetMix"), "réglage non géré signalé")
        }

        // .brushset : deux dossiers de pinceaux.
        let set = zip([("A/Brush.archive", [UInt8](archive)), ("B/Brush.archive", [UInt8](archive)), ("B/Grain.png", png),
                       ("brushset.plist", [])], deflate: true)
        let presets = try ProcreateBrushImport.read(data: set, fallbackName: "lot")
        XCTAssertEqual(presets.count, 2)
        XCTAssertNotNil(presets.first { $0.settings.grain != nil })
        XCTAssertThrowsError(try ProcreateBrushImport.read(data: zip([("x.txt", [1])], deflate: false), fallbackName: "x"))
    }

    func testNativeBrushRoundTripAndPNGTexture() throws {
        var settings = BrushSettings(radiusDegrees: 5, opacity: 0.7, hardness: 0.3, spacing: 0.4)
        let image = try ImageDecoder.decode(data: Data(try shapePNG()))
        settings.shape = BrushTextureImport.texture(from: image, name: "disque")
        settings.grain = BrushTextureImport.texture(from: image, name: "disque inversé", invert: true)
        settings.followStroke = true
        settings.grainScaleDegrees = 7
        let data = try NativeBrushFile.data(BrushPreset(name: "Mon pinceau", settings: settings))
        let back = try NativeBrushFile.preset(from: data)
        XCTAssertEqual(back.name, "Mon pinceau")
        XCTAssertEqual(back.settings.radiusDegrees, 5)
        XCTAssertTrue(back.settings.followStroke)
        XCTAssertEqual(back.settings.grainScaleDegrees, 7)
        let shape = try XCTUnwrap(back.settings.shape)
        XCTAssertEqual(shape.size, 32)
        for (a, b) in zip(shape.values, settings.shape!.values) { XCTAssertEqual(a, b, accuracy: 0.5 / 255 + 1e-6) }
        XCTAssertEqual(back.settings.grain!.values[16 * 32 + 16], 0, accuracy: 0.01, "inversée")
    }

    func testTimelapseRecordsAndExportsHEVC() async throws {
        let recorder = try TimelapseRecorder(directory: directory.appendingPathComponent("frames"))
        for i in 0..<8 {
            var rgba = [UInt8](repeating: 255, count: 128 * 64 * 4)
            for p in 0..<(128 * 64) { rgba[p * 4] = UInt8(i * 30); rgba[p * 4 + 1] = UInt8(p % 128 * 2) }
            recorder.append(rgba: rgba, width: 128, height: 64)
        }
        XCTAssertEqual(recorder.frameURLs.count, 8)

        for (name, view) in [("plat.mp4", TimelapseView.unfolded), ("sphere.mp4", .sphere(fovDegrees: 90, turns: 1))] {
            let url = directory.appendingPathComponent(name)
            try TimelapseExporter.export(frames: recorder.frameURLs, to: url, width: 256, height: 128, view: view, minimumDuration: 1)
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let formats = try await track.load(.formatDescriptions)
            XCTAssertEqual(formats.first.map { CMFormatDescriptionGetMediaSubType($0) }, kCMVideoCodecType_HEVC, "\(name) en H.265")
            let duration = try await asset.load(.duration)
            XCTAssertGreaterThan(duration.seconds, 1.5, "au moins la durée minimale + la dernière image tenue")
        }

        let saved = directory.appendingPathComponent("projet/timelapse")
        try FileManager.default.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try recorder.copy(to: saved)
        recorder.reset()
        XCTAssertEqual(recorder.frameCount, 0)
        recorder.replace(with: saved)
        XCTAssertEqual(recorder.frameCount, 8, "rechargé avec le projet")
        XCTAssertThrowsError(try TimelapseExporter.export(frames: [], to: directory.appendingPathComponent("vide.mp4"), width: 64, height: 32))
    }
}
