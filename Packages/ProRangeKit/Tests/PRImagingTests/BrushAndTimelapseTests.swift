import AVFoundation
import Compression
import Foundation
import PRCore
@testable import PRImaging
import XCTest

/// Faux pinceau Procreate : un objet archivé par NSKeyedArchiver avec des clés plates, comme `SilicaBrush`.
@objc(PRFakeBrush)
final class FakeBrush: NSObject, NSCoding {
    override init() {}
    required init?(coder: NSCoder) { nil }

    func encode(with coder: NSCoder) {
        coder.encode("Craie sèche", forKey: "name")
        coder.encode(0.5, forKey: "maxSize")
        coder.encode(0.2, forKey: "minSize")
        coder.encode(0.8, forKey: "maxOpacity")
        coder.encode(0.1, forKey: "plotSpacing")
        coder.encode(Double.pi / 2, forKey: "shapeAngle")
        coder.encode(0.24, forKey: "plotSpacingJitter")
        coder.encode(0.14, forKey: "plotJitter")
        coder.encode(0.47, forKey: "dynamicsJitterSize")
        coder.encode(2.0, forKey: "shapeScatter")
        coder.encode(true, forKey: "shapeFlipXJitter")
        coder.encode("Procreate_Library/Craie_Grain.png", forKey: "bundledGrainPath")
        coder.encode(1.0, forKey: "dynamicsPressureSize")
        coder.encode(0.6, forKey: "textureDepth")
        coder.encode(0.5, forKey: "shapeRoundness")
        coder.encode(1.0, forKey: "textureMovement")
        coder.encode(-0.45, forKey: "textureContrast")
        coder.encode(0.2, forKey: "dynamicsSpeedSize")
        coder.encode(true, forKey: "shapeRandomise")
        coder.encode(3.0, forKey: "wetMix")
    }
}

/// Courbe de pression archivée comme `ValkyrieMagnitudinalCurve` : un tableau de points « {x, y} ».
@objc(PRFakeCurve)
final class FakeCurve: NSObject, NSCoding {
    let points: [String]
    init(_ points: [String]) { self.points = points }
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) { coder.encode(points as NSArray, forKey: "points") }
}

/// Faux pinceau double : principal (avec courbe, flux, combinaison) ou secondaire.
@objc(PRFakeDualBrush)
final class FakeDualBrush: NSObject, NSCoding {
    let secondary: Bool
    init(secondary: Bool) { self.secondary = secondary }
    required init?(coder: NSCoder) { nil }

    func encode(with coder: NSCoder) {
        coder.encode("Double", forKey: "name")
        coder.encode(secondary ? 0.8 : 0.4, forKey: "maxSize")
        coder.encode(0.1, forKey: "plotSpacing")
        coder.encode(1.0, forKey: "dynamicsPressureSize")
        // Valeurs de Minke : rondeur selon la pression et l'inclinaison neutralisée par son minimum.
        coder.encode(1.0, forKey: "dynamicsPressureShapeRoundness")
        coder.encode(1.0, forKey: "dynamicsPressureShapeRoundnessMinimum")
        coder.encode(1.0, forKey: "dynamicsTiltShapeRoundness")
        coder.encode(secondary ? 0.4 : 1.0, forKey: "dynamicsTiltShapeRoundnessMinimum")
        guard !secondary else {
            coder.encode(true, forKey: "shapeInverted")
            return
        }
        coder.encode(0.0, forKey: "dynamicsMix")
        coder.encode(0.2, forKey: "dynamicsPressureMix")
        coder.encode(0.1, forKey: "dynamicsWetAccumulation")
        coder.encode(20.0, forKey: "dualBlendMode")
        coder.encode(0.25, forKey: "dynamicsPressureOpacityTransfer")
        coder.encode(0.1, forKey: "dynamicsPressureOpacity")
        coder.encode(0.7, forKey: "dynamicsGlazedFlow")
        coder.encode(0.1, forKey: "minSize")
        coder.encode(0.0, forKey: "textureApplication")
        coder.encode(1.0, forKey: "textureMovement")
        coder.encode(8.0, forKey: "grainBlendMode")
        coder.encode(0.05, forKey: "plotJitterLongitudinal")
        coder.encode(true, forKey: "renderingRecursiveMixing")
        coder.encode(true, forKey: "renderingModulatedTransfer")
        coder.encode(0.01, forKey: "dynamicsLoad")
        coder.encode(0.8, forKey: "dynamicsMixSoftening")
        coder.encode(0.0625, forKey: "shapeCount")
        coder.encode(0.36, forKey: "jitterShapeRoundness")
        coder.encode(0.3, forKey: "jitterShapeRoundnessX")
        coder.encode(FakeCurve(["{0.000000, 0.000000}", "{1.000000, 1.000000}", "{0.400000, 0.600000}"]),
                     forKey: "dynamicsPressureOverall")
    }
}

final class BrushAndTimelapseTests: XCTestCase {
    func testDualBrushCurvesAndFlowImport() throws {
        let primary = try NSKeyedArchiver.archivedData(withRootObject: FakeDualBrush(secondary: false), requiringSecureCoding: false)
        let secondary = try NSKeyedArchiver.archivedData(withRootObject: FakeDualBrush(secondary: true), requiringSecureCoding: false)
        let png = try shapePNG()
        let data = zip([("Brush.archive", [UInt8](primary)), ("Shape.png", png), ("Sub01/Brush.archive", [UInt8](secondary)),
                        ("Sub01/Shape.png", png),
                        ("Reset/Brush.archive", [UInt8](primary)), ("Reset/Sub01/Brush.archive", [UInt8](secondary))], deflate: true)
        let presets = try ProcreateBrushImport.read(data: data, fallbackName: "double")
        XCTAssertEqual(presets.count, 1, "le secondaire n'est pas un pinceau à part")
        let s = try XCTUnwrap(presets.first).settings
        let second = try XCTUnwrap(s.secondary, "secondaire importé")
        XCTAssertEqual(s.dualBlendMode, .hardMix)
        XCTAssertEqual(s.secondaryScale, second.radiusDegrees / s.radiusDegrees, accuracy: 1e-9)
        XCTAssertGreaterThan(s.secondaryScale, 1.5)
        XCTAssertEqual(s.pressureOpacityAmount, 0.25, accuracy: 1e-9)
        XCTAssertEqual(s.pressureFlowAmount, 0.1, accuracy: 1e-9)
        XCTAssertEqual(s.flow, 0.7, accuracy: 1e-9)
        XCTAssertEqual(s.pressureCurve.points.count, 3)
        XCTAssertEqual(s.pressureCurve.value(0.4), 0.6, accuracy: 1e-9)
        XCTAssertEqual(s.minimumSize, 0, "taille min = borne du curseur, pas taille à pression nulle")
        XCTAssertEqual(s.minSizeDegrees, 0.9, accuracy: 1e-9)
        XCTAssertEqual(s.maxSizeDegrees, s.radiusDegrees)
        XCTAssertTrue(s.grainMoving)
        XCTAssertEqual(s.grainMovement, 1, "rouleau")
        XCTAssertEqual(s.grainBlendMode, .linearBurn)
        XCTAssertEqual(s.longitudinalJitter, 0.05, accuracy: 1e-9)
        XCTAssertEqual(s.rendering, .uniformBlending)
        XCTAssertEqual(s.wetCharge, 0.01, accuracy: 1e-9)
        XCTAssertEqual(s.wetGrade, 0.8, accuracy: 1e-9)
        XCTAssertEqual(s.stampCount, 1, "0,0625 = 1 tampon, comme l'affiche Procreate")
        XCTAssertEqual(s.roundnessJitter, 0.36, accuracy: 1e-9)
        XCTAssertEqual(s.roundnessJitterX, 0.3, accuracy: 1e-9)
        XCTAssertEqual(s.pressureRoundness, 0, "minimum 100 % : la forme ne s'écrase pas")
        XCTAssertEqual(s.tiltRoundness, 0)
        XCTAssertEqual(second.tiltRoundness, 0.6, accuracy: 1e-9, "effet 100 %, minimum 40 %")
        XCTAssertFalse(s.wetMixActive, "dilution nulle : pas de mélange humide malgré tirage et charge")
        XCTAssertFalse(s.varyingColor)
        XCTAssertGreaterThan(try XCTUnwrap(s.shape).values[16 * 32 + 16], 0.9, "forme principale telle quelle")
        let invertedShape = try XCTUnwrap(second.shape)
        XCTAssertLessThan(invertedShape.values[16 * 32 + 16], 0.1, "forme secondaire inversée (shapeInverted)")
        XCTAssertGreaterThan(invertedShape.values[0], 0.9)

        // Le .prbrush garde tout : secondaire, combinaison, courbe, flux, rendu.
        var edited = s
        edited.rendering = .intenseGlaze
        let back = try NativeBrushFile.preset(from: NativeBrushFile.data(BrushPreset(name: "Double", settings: edited))).settings
        XCTAssertEqual(back.secondary?.radiusDegrees, second.radiusDegrees)
        XCTAssertEqual(back.dualBlendMode, .hardMix)
        XCTAssertEqual(back.pressureCurve, s.pressureCurve)
        XCTAssertEqual(back.flow, 0.7, accuracy: 1e-9)
        XCTAssertEqual(back.pressureFlowAmount, 0.1, accuracy: 1e-9)
        XCTAssertEqual(back.rendering, .intenseGlaze)
        XCTAssertEqual(back.grainBlendMode, .linearBurn)
        XCTAssertEqual(back.grainMovement, 1)
        XCTAssertEqual(back.longitudinalJitter, 0.05, accuracy: 1e-9)
        XCTAssertEqual(back.wetCharge, 0.01, accuracy: 1e-9)
        XCTAssertEqual(back.minSizeDegrees, s.minSizeDegrees)
    }

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
            let data = zip([("Brush.archive", [UInt8](archive)), ("Reset/Brush.archive", [UInt8](archive)), ("Shape.png", png),
                            ("QuickLook/Thumbnail.png", png)], deflate: deflate)
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
            XCTAssertEqual(preset.settings.grainSource, BuiltInBrushes.substituteGrain, "grain interne remplacé par le substitut")
            XCTAssertNotNil(preset.settings.grain, "grain dérivé (contraste appliqué)")
            XCTAssertEqual(preset.settings.shapeRoundness, 0.5, accuracy: 1e-9)
            XCTAssertTrue(preset.settings.grainMoving)
            XCTAssertEqual(preset.settings.grainContrast, -0.45, accuracy: 1e-9)
            XCTAssertEqual(preset.settings.speedSize, 0.2, accuracy: 1e-9)
            XCTAssertTrue(preset.settings.randomizeRotation)
            XCTAssertTrue(preset.ignored.contains { $0.contains("1 autres réglages") }, "réglage non géré signalé : \(preset.ignored)")
            XCTAssertEqual(preset.settings.spacingJitter, 0.24, accuracy: 1e-9)
            XCTAssertEqual(preset.settings.scatter, 0.14, accuracy: 1e-9)
            XCTAssertEqual(preset.settings.sizeJitter, 0.47, accuracy: 1e-9)
            XCTAssertEqual(preset.settings.rotationJitter, .pi, accuracy: 1e-9, "dispersion de forme 2 = rotation libre")
            XCTAssertTrue(preset.settings.randomFlip)
            XCTAssertTrue(preset.ignored.contains { $0.contains("Craie_Grain.png") }, "texture interne signalée")
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
        settings.taperStartLength = 3
        settings.stampCount = 5
        settings.grainMoving = true
        settings.tiltOpacity = 0.4
        settings.author = "Paul"
        let data = try NativeBrushFile.data(BrushPreset(name: "Mon pinceau", settings: settings))
        let back = try NativeBrushFile.preset(from: data)
        XCTAssertEqual(back.name, "Mon pinceau")
        XCTAssertEqual(back.settings.radiusDegrees, 5)
        XCTAssertTrue(back.settings.followStroke)
        XCTAssertEqual(back.settings.grainScaleDegrees, 7)
        XCTAssertEqual(back.settings.taperStartLength, 3)
        XCTAssertEqual(back.settings.stampCount, 5)
        XCTAssertTrue(back.settings.grainMoving)
        XCTAssertEqual(back.settings.tiltOpacity, 0.4)
        XCTAssertEqual(back.settings.author, "Paul")
        let shape = try XCTUnwrap(back.settings.shape)
        XCTAssertEqual(shape.size, 32)
        for (a, b) in Swift.zip(shape.values, settings.shape!.values) { XCTAssertEqual(a, b, accuracy: 0.5 / 255 + 1e-6) }
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
