import Foundation

/// Écrivain Radiance `.hdr` (RGBE, compression RLE par ligne), en flux. Pas d'alpha : les pixels sont pris tels quels
/// (le papier doit déjà être composé par la source si on le veut).
public enum RadianceWriter {
    public static func write(to url: URL, width: Int, height: Int, bandHeight: Int = 256, rows: RowProvider,
                             progress: ExportProgress = { _ in true }) throws {
        guard width > 0, height > 0, bandHeight > 0 else { throw ExportError.invalidDimensions }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        var completed = false
        defer {
            try? handle.close()
            if !completed { try? FileManager.default.removeItem(at: url) }
        }
        let header = "#?RADIANCE\n# ProRange Creator\nFORMAT=32-bit_rle_rgbe\n\n-Y \(height) +X \(width)\n"
        try handle.write(contentsOf: Data(header.utf8))

        var y = 0
        while y < height {
            let count = min(bandHeight, height - y)
            let band = try rows(y, count)
            precondition(band.count == count * width, "bande de taille incorrecte")
            var out: [UInt8] = []
            out.reserveCapacity(count * width * 4)
            for line in 0..<count {
                let rgbe = band[(line * width)..<((line + 1) * width)].map(encode)
                out.append(contentsOf: encodeScanline(rgbe, width: width))
            }
            try handle.write(contentsOf: Data(out))
            y += count
            guard progress(Double(y) / Double(height)) else { throw ExportError.cancelled }
        }
        completed = true
    }

    /// RGBE : mantisse commune sur 8 bits, exposant partagé.
    static func encode(_ p: SIMD4<Float>) -> SIMD4<UInt8> {
        let r = max(0, p.x), g = max(0, p.y), b = max(0, p.z)
        let v = max(r, g, b)
        guard v >= 1e-32 else { return .zero }
        let e = Int(Foundation.floor(Foundation.log2(v))) + 1
        let scale = Float(256) / Float(sign: .plus, exponent: e, significand: 1)
        func byte(_ c: Float) -> UInt8 { UInt8(min(255, c * scale)) }
        return SIMD4<UInt8>(byte(r), byte(g), byte(b), UInt8(clamping: e + 128))
    }

    static func decode(_ p: SIMD4<UInt8>) -> SIMD3<Float> {
        guard p.w > 0 else { return .zero }
        let f = Float(sign: .plus, exponent: Int(p.w) - 136, significand: 1)
        return SIMD3<Float>(Float(p.x) + 0.5, Float(p.y) + 0.5, Float(p.z) + 0.5) * f
    }

    /// Ligne au format RLE « nouveau style » (largeurs 8 à 32 767), sinon pixels bruts.
    static func encodeScanline(_ pixels: [SIMD4<UInt8>], width: Int) -> [UInt8] {
        guard (8..<32768).contains(width) else {
            return pixels.flatMap { [$0.x, $0.y, $0.z, $0.w] }
        }
        var out: [UInt8] = [2, 2, UInt8(width >> 8), UInt8(width & 0xFF)]
        for k in 0..<4 { out.append(contentsOf: rle(pixels.map { $0[k] })) }
        return out
    }

    /// Codage par plages de Greg Ward : plages ≥ 4 octets identiques (128 + n, octet), sinon littéraux (n ≤ 128, octets).
    static func rle(_ data: [UInt8]) -> [UInt8] {
        let minRun = 4
        let n = data.count
        var out: [UInt8] = []
        var cur = 0
        while cur < n {
            var begRun = cur
            var runCount = 0
            var oldRunCount = 0
            while runCount < minRun && begRun < n {
                begRun += runCount
                oldRunCount = runCount
                runCount = 1
                while begRun + runCount < n && runCount < 127 && data[begRun] == data[begRun + runCount] { runCount += 1 }
            }
            if oldRunCount > 1 && oldRunCount == begRun - cur {
                out.append(UInt8(128 + oldRunCount))
                out.append(data[cur])
                cur = begRun
            }
            while cur < begRun {
                let literal = min(128, begRun - cur)
                out.append(UInt8(literal))
                out.append(contentsOf: data[cur..<(cur + literal)])
                cur += literal
            }
            if runCount >= minRun && begRun < n {
                out.append(UInt8(128 + runCount))
                out.append(data[begRun])
                cur += runCount
            }
        }
        return out
    }
}

/// Lecteur Radiance `.hdr` (RLE nouveau style ou pixels bruts, orientation -Y +X).
public enum RadianceReader {
    public enum Failure: Error {
        case notRadiance
        case unsupported(String)
        case corrupt
    }

    public struct Image {
        public let width: Int
        public let height: Int
        public let pixels: [SIMD3<Float>]
    }

    public static func read(_ url: URL) throws -> Image {
        let bytes = [UInt8](try Data(contentsOf: url))
        var offset = 0
        func readLine() throws -> String {
            guard let end = bytes[offset...].firstIndex(of: 0x0A) else { throw Failure.corrupt }
            defer { offset = end + 1 }
            return String(decoding: bytes[offset..<end], as: UTF8.self)
        }
        guard try readLine().hasPrefix("#?") else { throw Failure.notRadiance }
        while try !readLine().isEmpty {}
        let parts = try readLine().split(separator: " ")
        guard parts.count == 4, parts[0] == "-Y", parts[2] == "+X", let height = Int(parts[1]), let width = Int(parts[3]) else {
            throw Failure.unsupported("orientation")
        }

        var pixels: [SIMD3<Float>] = []
        pixels.reserveCapacity(width * height)
        for _ in 0..<height {
            guard offset + 4 <= bytes.count else { throw Failure.corrupt }
            if bytes[offset] == 2, bytes[offset + 1] == 2, Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3]) == width {
                offset += 4
                var channels = [[UInt8]](repeating: [], count: 4)
                for k in 0..<4 {
                    while channels[k].count < width {
                        guard offset < bytes.count else { throw Failure.corrupt }
                        let count = Int(bytes[offset])
                        offset += 1
                        if count > 128 {
                            guard offset < bytes.count else { throw Failure.corrupt }
                            channels[k].append(contentsOf: repeatElement(bytes[offset], count: count - 128))
                            offset += 1
                        } else {
                            guard count > 0, offset + count <= bytes.count else { throw Failure.corrupt }
                            channels[k].append(contentsOf: bytes[offset..<(offset + count)])
                            offset += count
                        }
                    }
                    guard channels[k].count == width else { throw Failure.corrupt }
                }
                for x in 0..<width {
                    pixels.append(RadianceWriter.decode([channels[0][x], channels[1][x], channels[2][x], channels[3][x]]))
                }
            } else {
                guard offset + width * 4 <= bytes.count else { throw Failure.corrupt }
                for x in 0..<width {
                    let o = offset + x * 4
                    pixels.append(RadianceWriter.decode([bytes[o], bytes[o + 1], bytes[o + 2], bytes[o + 3]]))
                }
                offset += width * 4
            }
        }
        return Image(width: width, height: height, pixels: pixels)
    }
}
