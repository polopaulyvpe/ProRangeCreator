import Foundation
import PRCore
@testable import PRImaging
import PRStorage
import XCTest

final class PSDWriterTests: XCTestCase {
    func testPackBitsRoundTrip() {
        let rows: [[UInt8]] = [[], [7], [1, 2, 3, 4], [5, 5, 5, 5, 5, 9, 9, 1, 2, 2, 3],
                               Array(repeating: 200, count: 300), (0..<300).map { UInt8($0 % 251) }]
        for row in rows {
            var out: [UInt8] = []
            ForeignBrushImport.unpackBits(PSDWriter.packBits(row[...]), row: row.count, into: &out)
            XCTAssertEqual(out, row)
        }
        XCTAssertEqual(PSDWriter.packBits(Array(repeating: 0, count: 256)[...]).count, 4, "deux paquets répétés")
    }

    /// Relit le fichier : en-tête, calques (noms, modes, opacité, visibilité), longueurs, image composée.
    func testLayeredFileStructure() throws {
        let stack = LayerStack(width: 64, height: 32)
        stack.items[0].layer!.stamp(SphericalDab(center: [0, 0, -1], radius: 0.6, hardness: 1, color: [1, 0, 0, 1]))
        let top = try XCTUnwrap(stack.addLayer())
        stack.update(top.id) {
            $0.name = "Ciel étoilé"
            $0.blendMode = .screen
            $0.opacity = 0.5
            $0.isVisible = false
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("psd-\(UUID().uuidString).psd")
        defer { try? FileManager.default.removeItem(at: url) }
        try PSDWriter.export(stack, paper: nil, to: url)

        var r = BigEndianReader([UInt8](try Data(contentsOf: url)))
        XCTAssertEqual(r.take(4), Array("8BPS".utf8))
        XCTAssertEqual(r.u16(), 1)
        _ = r.take(6)
        XCTAssertEqual(r.u16(), 4, "composée avec alpha (fond transparent)")
        XCTAssertEqual(r.u32(), 32)
        XCTAssertEqual(r.u32(), 64)
        XCTAssertEqual(r.u16(), 8)
        XCTAssertEqual(r.u16(), 3, "RVB")
        XCTAssertEqual(r.u32(), 0)
        XCTAssertEqual(r.u32(), 0)
        let sectionLength = Int(try XCTUnwrap(r.u32()))
        let sectionStart = r.at
        let infoLength = Int(try XCTUnwrap(r.u32()))
        let count = Int16(bitPattern: try XCTUnwrap(r.u16()))
        XCTAssertEqual(count, -2)
        var dataLengths: [Int] = []
        var names: [String] = []
        var keys: [String] = []
        var opacities: [UInt8] = []
        var flags: [UInt8] = []
        for _ in 0..<2 {
            XCTAssertEqual(r.u32(), 0)
            XCTAssertEqual(r.u32(), 0)
            XCTAssertEqual(r.u32(), 32)
            XCTAssertEqual(r.u32(), 64)
            XCTAssertEqual(r.u16(), 4)
            for _ in 0..<4 {
                _ = r.u16()
                dataLengths.append(Int(try XCTUnwrap(r.u32())))
            }
            XCTAssertEqual(r.take(4), Array("8BIM".utf8))
            keys.append(String(decoding: try XCTUnwrap(r.take(4)), as: UTF8.self))
            opacities.append(try XCTUnwrap(r.u8()))
            _ = r.u8()
            flags.append(try XCTUnwrap(r.u8()))
            _ = r.u8()
            let extra = Int(try XCTUnwrap(r.u32()))
            var e = BigEndianReader(try XCTUnwrap(r.take(extra)))
            XCTAssertEqual(e.u32(), 0)
            XCTAssertEqual(e.u32(), 0)
            let n = Int(try XCTUnwrap(e.u8()))
            _ = e.take(n)
            // Nom Pascal complété à un multiple de 4 octets (longueur comprise).
            while (e.at - 8) % 4 != 0 && e.at < extra { _ = e.u8() }
            XCTAssertEqual(e.take(4), Array("8BIM".utf8))
            XCTAssertEqual(e.take(4), Array("luni".utf8))
            _ = e.u32()
            names.append(try XCTUnwrap(e.unicode()))
        }
        XCTAssertEqual(keys, ["norm", "scrn"])
        XCTAssertEqual(opacities, [255, 128])
        XCTAssertEqual(flags, [0, 2], "le second est caché")
        XCTAssertEqual(names[1], "Ciel étoilé")
        // Données des canaux : chacune commence par la compression 1 et ses longueurs de rangées tombent juste.
        for length in dataLengths {
            let channel = try XCTUnwrap(r.take(length))
            var c = BigEndianReader(channel)
            XCTAssertEqual(c.u16(), 1)
            var total = 0
            for _ in 0..<32 { total += Int(try XCTUnwrap(c.u16())) }
            XCTAssertEqual(2 + 64 + total, length)
        }
        r.at = sectionStart + 4 + infoLength
        XCTAssertEqual(r.u32(), 0, "pas de masque global")
        XCTAssertEqual(r.at, sectionStart + sectionLength)
        // Image composée : compression, 4 × 32 longueurs, puis les rangées ; on décode le rouge au centre.
        XCTAssertEqual(r.u16(), 1)
        var lengths: [Int] = []
        for _ in 0..<(4 * 32) { lengths.append(Int(try XCTUnwrap(r.u16()))) }
        var planes: [[UInt8]] = []
        for c in 0..<4 {
            var plane: [UInt8] = []
            for y in 0..<32 { ForeignBrushImport.unpackBits(try XCTUnwrap(r.take(lengths[c * 32 + y])), row: 64, into: &plane) }
            planes.append(plane)
        }
        XCTAssertEqual(r.remaining, 0, "fin du fichier")
        let center = 16 * 64 + 32
        XCTAssertEqual(planes[0][center], 255, "rouge au centre (le calque caché n'y est pour rien)")
        XCTAssertEqual(planes[3][center], 255)
        XCTAssertEqual(planes[3][0], 0, "transparent aux pôles")
    }
}
