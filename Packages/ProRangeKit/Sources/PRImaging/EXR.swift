import Foundation

/// Fournit des bandes de lignes : `count` lignes à partir de `y`, en RGBA linéaire prémultiplié, ligne par ligne.
public typealias RowProvider = (_ y: Int, _ count: Int) throws -> [SIMD4<Float>]

/// Progression de 0 à 1 ; renvoyer `false` annule l'export.
public typealias ExportProgress = (Double) -> Bool

public enum ExportError: Error, Equatable {
    case cancelled
    case invalidDimensions
}

public enum EXRPixelType: String, CaseIterable, Sendable {
    case half
    case float

    var code: Int32 { self == .half ? 1 : 2 }
    var size: Int { self == .half ? 2 : 4 }
    public var label: String { self == .half ? "16 bits (half)" : "32 bits (float)" }
}

public enum EXRCompression: String, CaseIterable, Sendable {
    case none
    case zip

    var code: UInt8 { self == .none ? 0 : 3 }
    var linesPerChunk: Int { self == .none ? 1 : 16 }
    public var label: String { self == .none ? "Aucune" : "ZIP" }
}

/// Écrivain OpenEXR minimal, en flux : image simple partie, lignes croissantes, canaux (A,) B, G, R.
/// Compression aucune ou ZIP (blocs de 16 lignes, prédicteur et réordonnancement d'OpenEXR, flux zlib). PIZ n'est pas géré.
public enum EXRWriter {
    public static func write(to url: URL, width: Int, height: Int, pixelType: EXRPixelType, compression: EXRCompression,
                             includeAlpha: Bool, bandHeight: Int = 256, rows: RowProvider,
                             progress: ExportProgress = { _ in true }) throws {
        guard width > 0, height > 0, bandHeight % 16 == 0 else { throw ExportError.invalidDimensions }
        let channels = includeAlpha ? ["A", "B", "G", "R"] : ["B", "G", "R"]
        let header = makeHeader(width: width, height: height, channels: channels, pixelType: pixelType, compression: compression)
        let chunkCount = (height + compression.linesPerChunk - 1) / compression.linesPerChunk

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        var completed = false
        defer {
            try? handle.close()
            if !completed { try? FileManager.default.removeItem(at: url) }
        }
        try handle.write(contentsOf: Data(header))
        let tableOffset = UInt64(header.count)
        try handle.write(contentsOf: Data(count: chunkCount * 8)) // table des offsets, remplie à la fin
        var offsets: [UInt64] = []
        offsets.reserveCapacity(chunkCount)
        var position = tableOffset + UInt64(chunkCount * 8)

        var y = 0
        while y < height {
            let count = min(bandHeight, height - y)
            let band = try rows(y, count)
            precondition(band.count == count * width, "bande de taille incorrecte")
            var line = 0
            while line < count {
                let lines = min(compression.linesPerChunk, count - line)
                let raw = packLines(band, from: line, lines: lines, width: width, channels: channels, pixelType: pixelType)
                let payload = compression == .zip ? (Zlib.compress(zipPreprocess(raw)) ?? raw) : raw
                var chunk = ByteWriter()
                chunk.append(Int32(y + line))
                chunk.append(Int32(payload.count))
                chunk.append(payload)
                try handle.write(contentsOf: Data(chunk.bytes))
                offsets.append(position)
                position += UInt64(chunk.bytes.count)
                line += lines
            }
            y += count
            guard progress(Double(y) / Double(height)) else { throw ExportError.cancelled }
        }

        var table = ByteWriter()
        for offset in offsets { table.append(offset) }
        try handle.seek(toOffset: tableOffset)
        try handle.write(contentsOf: Data(table.bytes))
        completed = true
    }

    static func makeHeader(width: Int, height: Int, channels: [String], pixelType: EXRPixelType,
                           compression: EXRCompression) -> [UInt8] {
        var w = ByteWriter()
        w.append([0x76, 0x2F, 0x31, 0x01]) // nombre magique
        w.append(UInt32(2))                // version 2, image simple partie en lignes

        var chlist = ByteWriter()
        for name in channels {
            chlist.appendCString(name)
            chlist.append(pixelType.code)
            chlist.append(UInt8(0))         // pLinear
            chlist.append([0, 0, 0])        // réservé
            chlist.append(Int32(1))         // xSampling
            chlist.append(Int32(1))         // ySampling
        }
        chlist.append(UInt8(0))
        attribute(&w, "channels", "chlist", chlist.bytes)
        attribute(&w, "compression", "compression", [compression.code])

        var box = ByteWriter()
        box.append(Int32(0))
        box.append(Int32(0))
        box.append(Int32(width - 1))
        box.append(Int32(height - 1))
        attribute(&w, "dataWindow", "box2i", box.bytes)
        attribute(&w, "displayWindow", "box2i", box.bytes)
        attribute(&w, "lineOrder", "lineOrder", [0])

        var one = ByteWriter()
        one.append(Float(1))
        attribute(&w, "pixelAspectRatio", "float", one.bytes)
        var center = ByteWriter()
        center.append(Float(0))
        center.append(Float(0))
        attribute(&w, "screenWindowCenter", "v2f", center.bytes)
        attribute(&w, "screenWindowWidth", "float", one.bytes)
        w.append(UInt8(0)) // fin de l'en-tête
        return w.bytes
    }

    private static func attribute(_ w: inout ByteWriter, _ name: String, _ type: String, _ value: [UInt8]) {
        w.appendCString(name)
        w.appendCString(type)
        w.append(Int32(value.count))
        w.append(value)
    }

    /// Lignes en format OpenEXR : pour chaque ligne, chaque canal (ordre alphabétique) sur toute la largeur.
    static func packLines(_ band: [SIMD4<Float>], from first: Int, lines: Int, width: Int,
                          channels: [String], pixelType: EXRPixelType) -> [UInt8] {
        var w = ByteWriter()
        w.bytes.reserveCapacity(lines * width * channels.count * pixelType.size)
        for line in first..<(first + lines) {
            let row = line * width
            for name in channels {
                let k = name == "R" ? 0 : name == "G" ? 1 : name == "B" ? 2 : 3
                for x in 0..<width {
                    let v = band[row + x][k]
                    if pixelType == .half { w.append(Float16(v)) } else { w.append(v) }
                }
            }
        }
        return w.bytes
    }

    /// Préparation ZIP d'OpenEXR : octets pairs puis impairs, puis différences successives (+128).
    static func zipPreprocess(_ raw: [UInt8]) -> [UInt8] {
        let n = raw.count
        var t = [UInt8](repeating: 0, count: n)
        let half = (n + 1) / 2
        for i in 0..<n {
            if i % 2 == 0 { t[i / 2] = raw[i] } else { t[half + i / 2] = raw[i] }
        }
        guard n > 1 else { return t }
        var previous = Int(t[0])
        for i in 1..<n {
            let current = Int(t[i])
            t[i] = UInt8(truncatingIfNeeded: current - previous + 128 + 256)
            previous = current
        }
        return t
    }

    /// Inverse de `zipPreprocess`.
    static func zipPostprocess(_ t: [UInt8]) -> [UInt8] {
        let n = t.count
        guard n > 0 else { return [] }
        var d = t
        for i in 1..<n { d[i] = UInt8(truncatingIfNeeded: Int(d[i - 1]) + Int(d[i]) - 128) }
        var raw = [UInt8](repeating: 0, count: n)
        let half = (n + 1) / 2
        for i in 0..<n { raw[i] = i % 2 == 0 ? d[i / 2] : d[half + i / 2] }
        return raw
    }
}

/// Lecteur OpenEXR minimal (ce que `EXRWriter` produit : lignes, aucune compression ou ZIP/ZIPS, half ou float).
/// Sert à relire les exports dans les tests, et servira à l'import.
public enum EXRReader {
    public enum Failure: Error {
        case notEXR
        case unsupported(String)
    }

    public struct Image {
        public let width: Int
        public let height: Int
        /// RGBA, alpha à 1 si absent.
        public let pixels: [SIMD4<Float>]
        public let channels: [String]
    }

    public static func read(_ url: URL) throws -> Image {
        var r = ByteReader([UInt8](try Data(contentsOf: url)))
        guard try r.read(UInt32.self) == 20_000_630 else { throw Failure.notEXR }
        let version = try r.read(UInt32.self)
        guard version & 0xFF == 2, version & 0x1200 == 0 else { throw Failure.unsupported("version \(version)") }

        var channels: [(name: String, type: Int32)] = []
        var compression: UInt8 = 0
        var window: (Int, Int, Int, Int)?
        while true {
            let name = try r.readCString()
            if name.isEmpty { break }
            let type = try r.readCString()
            let size = Int(try r.read(Int32.self))
            var value = ByteReader(try r.readBytes(size))
            switch (name, type) {
            case ("channels", "chlist"):
                while true {
                    let channel = try value.readCString()
                    if channel.isEmpty { break }
                    let pixelType = try value.read(Int32.self)
                    _ = try value.readBytes(12)
                    channels.append((channel, pixelType))
                }
            case ("compression", _):
                compression = try value.read(UInt8.self)
            case ("dataWindow", "box2i"):
                window = (Int(try value.read(Int32.self)), Int(try value.read(Int32.self)),
                          Int(try value.read(Int32.self)), Int(try value.read(Int32.self)))
            default:
                break
            }
        }
        guard let (x0, y0, x1, y1) = window else { throw Failure.unsupported("dataWindow manquant") }
        let width = x1 - x0 + 1
        let height = y1 - y0 + 1
        let linesPerChunk: Int
        switch compression {
        case 0, 2: linesPerChunk = 1
        case 3: linesPerChunk = 16
        default: throw Failure.unsupported("compression \(compression)")
        }
        let chunkCount = (height + linesPerChunk - 1) / linesPerChunk
        var offsets: [Int] = []
        for _ in 0..<chunkCount { offsets.append(Int(try r.read(UInt64.self))) }

        let bytesPerLine = channels.reduce(0) { $0 + ($1.type == 1 ? 2 : 4) } * width
        var pixels = [SIMD4<Float>](repeating: [0, 0, 0, 1], count: width * height)
        for offset in offsets {
            var chunk = ByteReader(r.bytes, offset: offset)
            let lineY = Int(try chunk.read(Int32.self)) - y0
            let size = Int(try chunk.read(Int32.self))
            let lines = min(linesPerChunk, height - lineY)
            let expected = bytesPerLine * lines
            var data = try chunk.readBytes(size)
            if compression != 0, size < expected {
                data = EXRWriter.zipPostprocess(try Zlib.decompress(data, expectedSize: expected))
            }
            var line = ByteReader(data)
            for l in 0..<lines {
                let row = (lineY + l) * width
                for channel in channels {
                    let k: Int? = ["R": 0, "G": 1, "B": 2, "A": 3][channel.name]
                    for x in 0..<width {
                        let v: Float = channel.type == 1 ? Float(Float16(bitPattern: try line.read(UInt16.self))) : try line.readFloat()
                        if let k { pixels[row + x][k] = v }
                    }
                }
            }
        }
        return Image(width: width, height: height, pixels: pixels, channels: channels.map(\.name))
    }
}
