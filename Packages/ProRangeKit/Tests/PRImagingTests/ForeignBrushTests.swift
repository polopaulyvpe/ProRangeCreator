import Foundation
import PRCore
@testable import PRImaging
import XCTest

/// Pinceaux Photoshop, GIMP et Krita, fabriqués octet par octet.
final class ForeignBrushTests: XCTestCase {
    private func u16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    private func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (24 - 8 * UInt32($0))) & 0xFF) } }
    private func i32(_ v: Int32) -> [UInt8] { u32(UInt32(bitPattern: v)) }
    private func f64(_ v: Double) -> [UInt8] { (0..<8).map { UInt8((v.bitPattern >> (56 - 8 * UInt64($0))) & 0xFF) } }
    private func unicode(_ s: String) -> [UInt8] {
        let units = Array(s.utf16) + [0]
        return u32(UInt32(units.count)) + units.flatMap { u16($0) }
    }
    private func key(_ s: String) -> [UInt8] { s.count == 4 ? u32(0) + Array(s.utf8) : u32(UInt32(s.count)) + Array(s.utf8) }

    /// Pinceau GIMP version 2 : image 3 × 2 en niveaux de gris.
    private func gbr(name: String, pixels: [UInt8], width: UInt32 = 3, height: UInt32 = 2, spacing: UInt32 = 25) -> [UInt8] {
        let nameBytes = Array(name.utf8) + [0]
        return u32(UInt32(28 + nameBytes.count)) + u32(2) + u32(width) + u32(height) + u32(1) + Array("GIMP".utf8) + u32(spacing)
            + nameBytes + pixels
    }

    func testGimpBrushAndPipe() throws {
        let brush = gbr(name: "Craie", pixels: [0, 128, 255, 255, 128, 0])
        let presets = try ForeignBrushImport.read(data: Data(brush), fileName: "craie.gbr")
        XCTAssertEqual(presets.count, 1)
        XCTAssertEqual(presets[0].name, "Craie")
        XCTAssertEqual(presets[0].settings.spacing, 0.5, accuracy: 1e-9, "25 % du diamètre = 50 % du rayon")
        XCTAssertNotNil(presets[0].settings.shape)
        let tip = try XCTUnwrap(ForeignBrushImport.gimpBrush(brush)?.tip)
        XCTAssertEqual(tip.pixels, [0, 128, 255, 255, 128, 0])

        // Pipe : la première image vide est passée au profit de la suivante.
        let pipe = Array("Herbe\n2 ncells:2 dim:1\n".utf8) + gbr(name: "", pixels: [UInt8](repeating: 0, count: 6))
            + gbr(name: "brin", pixels: [9, 9, 9, 9, 9, 9])
        let tips = ForeignBrushImport.gimpPipe(pipe)
        XCTAssertEqual(tips.count, 2)
        XCTAssertEqual(tips[0].name, "brin")
        XCTAssertEqual(try ForeignBrushImport.read(data: Data(pipe), fileName: "herbe.gih").first?.name, "brin")
    }

    func testGimpGeneratedBrush() throws {
        let text = "GIMP-VBR\n1.5\nOvale\ncircle\n20\n10\n2\n0.75\n2\n30\n"
        let preset = try XCTUnwrap(try ForeignBrushImport.read(data: Data(text.utf8), fileName: "ovale.vbr").first)
        XCTAssertEqual(preset.name, "Ovale")
        XCTAssertEqual(preset.settings.hardness, 0.75, accuracy: 1e-9)
        XCTAssertEqual(preset.settings.shapeRoundness, 0.5, accuracy: 1e-9, "rapport 2 : moitié moins haut")
        XCTAssertEqual(preset.settings.shapeRotationDegrees, 30, accuracy: 1e-9)
        XCTAssertEqual(preset.settings.spacing, 0.4, accuracy: 1e-9)
    }

    func testPackBits() {
        var out: [UInt8] = []
        // 2 littéraux (1, 2), puis 4 fois 7, puis un octet de bourrage (−128) ignoré.
        ForeignBrushImport.unpackBits([1, 1, 2, 0xFD, 7, 0x80], row: 6, into: &out)
        XCTAssertEqual(out, [1, 2, 7, 7, 7, 7])
        var short: [UInt8] = []
        ForeignBrushImport.unpackBits([0, 5], row: 3, into: &short)
        XCTAssertEqual(short, [5, 0, 0], "rangée courte complétée")
    }

    /// Tampon d'ABR version 2 : en-tête, nom, rectangle, profondeur, compression et image.
    private func abrTip(name: String, compressed: Bool) -> [UInt8] {
        var body = u32(0) + u16(30) + unicode(name) + [1] + [UInt8](repeating: 0, count: 8)
        body += i32(0) + i32(0) + i32(2) + i32(3) + u16(8) + [compressed ? 1 : 0]
        if compressed {
            // Deux rangées de 3 : [5, 5, 5] et [1, 2, 3].
            body += u16(2) + u16(4) + [0xFE, 5] + [2, 1, 2, 3]
        } else {
            body += [5, 5, 5, 1, 2, 3]
        }
        return u16(2) + u32(UInt32(body.count)) + body
    }

    func testPhotoshopOldVersions() throws {
        let computed = u16(1) + u32(4) + [0, 0, 0, 0]
        let file = u16(2) + u16(3) + computed + abrTip(name: "Brosse", compressed: false) + abrTip(name: "Éponge", compressed: true)
        let presets = try ForeignBrushImport.read(data: Data(file), fileName: "set.abr")
        XCTAssertEqual(presets.map(\.name), ["Brosse", "Éponge"], "le tampon calculé est passé")
        XCTAssertEqual(presets[0].settings.spacing, 0.6, accuracy: 1e-9)
        var r = BigEndianReader(file)
        _ = r.u16()
        let tips = ForeignBrushImport.abrOld(&r, version: 2)
        XCTAssertEqual(tips[1].pixels, [5, 5, 5, 1, 2, 3])
        XCTAssertEqual(tips[0].pixels, tips[1].pixels, "brut et compressé donnent la même image")
    }

    func testPhotoshopSectionsWithPreset() throws {
        // Échantillon (version 6.1) : identifiant, rectangle, image brute 2 × 2.
        let id = "abc-123"
        var sample = [UInt8(id.utf8.count)] + Array(id.utf8) + [UInt8](repeating: 0, count: 10)
        sample += i32(0) + i32(0) + i32(2) + i32(2) + u16(8) + [0] + [10, 20, 30, 40]
        var samp = u32(UInt32(sample.count)) + sample
        while samp.count % 4 != 0 { samp.append(0) }

        // Descripteur : un préréglage « Fusain » dont le tampon nomme l'échantillon, espacé de 50 %, tourné de 45°.
        let tip = unicode("") + key("brushTip") + u32(4)
            + key("Spcn") + Array("UntF".utf8) + Array("#Prc".utf8) + f64(50)
            + key("Angl") + Array("UntF".utf8) + Array("#Ang".utf8) + f64(45)
            + key("Rndn") + Array("UntF".utf8) + Array("#Prc".utf8) + f64(80)
            + key("sampledData") + Array("TEXT".utf8) + unicode(id)
        let preset = unicode("") + key("brushPreset") + u32(3)
            + key("Nm  ") + Array("TEXT".utf8) + unicode("Fusain")
            + key("Brsh") + Array("Objc".utf8) + tip
            + key("useScatter") + Array("bool".utf8) + [1]
        let desc = u32(16) + unicode("") + key("null") + u32(1) + key("Brsh") + Array("VlLs".utf8) + u32(1) + Array("Objc".utf8) + preset
        var file = u16(6) + u16(1)
        file += Array("8BIM".utf8) + Array("samp".utf8) + u32(UInt32(samp.count)) + samp
        var padded = desc
        while padded.count % 4 != 0 { padded.append(0) }
        file += Array("8BIM".utf8) + Array("desc".utf8) + u32(UInt32(desc.count)) + padded

        let presets = try ForeignBrushImport.read(data: Data(file), fileName: "fusain.abr")
        XCTAssertEqual(presets.count, 1, "l'échantillon nommé n'est pas compté deux fois")
        let fusain = presets[0]
        XCTAssertEqual(fusain.name, "Fusain")
        XCTAssertEqual(fusain.settings.spacing, 1, accuracy: 1e-9)
        XCTAssertEqual(fusain.settings.shapeRotationDegrees, 45, accuracy: 1e-9)
        XCTAssertEqual(fusain.settings.shapeRoundness, 0.8, accuracy: 1e-9)
        XCTAssertNotNil(fusain.settings.shape)
        XCTAssertTrue(fusain.ignored.contains { $0.contains("useScatter") })
    }

    /// PNG minimal portant un texte (les sommes de contrôle ne sont pas vérifiées à la lecture).
    private func png(texts: [(String, String)]) -> [UInt8] {
        var out: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        func chunk(_ type: String, _ data: [UInt8]) {
            out += u32(UInt32(data.count)) + Array(type.utf8) + data + u32(0)
        }
        chunk("IHDR", u32(1) + u32(1) + [8, 0, 0, 0, 0])
        for (k, v) in texts { chunk("tEXt", Array(k.utf8) + [0] + Array(v.utf8)) }
        chunk("IEND", [])
        return out
    }

    func testKritaPresets() throws {
        let auto = """
        <Preset name="Doux" paintopid="paintbrush"><param name="brush_definition" type="string"><![CDATA[<Brush type="auto_brush" spacing="0.2" angle="0"><MaskGenerator type="circle" radius="10" ratio="1" hfade="0.3" vfade="0.3" spikes="2"/></Brush>]]></param><param name="OpacityValue" type="string"><![CDATA[0.5]]></param><param name="PressureSize" type="string"><![CDATA[true]]></param></Preset>
        """
        let soft = try XCTUnwrap(try ForeignBrushImport.read(data: Data(png(texts: [("preset", auto)])), fileName: "doux.kpp").first)
        XCTAssertEqual(soft.name, "Doux")
        XCTAssertEqual(soft.settings.hardness, 0.7, accuracy: 1e-9)
        XCTAssertEqual(soft.settings.spacing, 0.4, accuracy: 1e-9)
        XCTAssertEqual(soft.settings.opacity, 0.5, accuracy: 1e-9)
        XCTAssertTrue(soft.settings.pressureAffectsSize)
        XCTAssertFalse(soft.settings.pressureAffectsOpacity)

        // Tampon image embarqué (Krita 5) : un pinceau GIMP en base64.
        let tip = gbr(name: "grain", pixels: [255, 0, 255, 0, 255, 0]).map { $0 }
        let embedded = """
        <Preset name="Grain" paintopid="paintbrush"><param name="brush_definition" type="string"><![CDATA[<Brush type="gbr_brush" filename="grain.gbr" spacing="0.5" angle="0"/>]]></param><resources><resource type="brushes" filename="grain.gbr" name="grain">\(Data(tip).base64EncodedString())</resource></resources></Preset>
        """
        let grain = try XCTUnwrap(try ForeignBrushImport.read(data: Data(png(texts: [("preset", embedded)])), fileName: "grain.kpp").first)
        XCTAssertEqual(grain.name, "Grain")
        XCTAssertNotNil(grain.settings.shape)
        XCTAssertEqual(grain.settings.spacing, 1, accuracy: 1e-9)

        XCTAssertThrowsError(try ForeignBrushImport.read(data: Data(png(texts: [])), fileName: "vide.kpp"))
    }
}
