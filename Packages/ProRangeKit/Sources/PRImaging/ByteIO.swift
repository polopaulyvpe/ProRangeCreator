import Compression
import Foundation

/// Écriture petit-boutiste dans un tampon d'octets.
struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func append(_ value: Float) { append(value.bitPattern) }
    mutating func append(_ value: Float16) { append(value.bitPattern) }

    /// Chaîne terminée par un octet nul.
    mutating func appendCString(_ s: String) {
        bytes.append(contentsOf: Array(s.utf8))
        bytes.append(0)
    }

    mutating func append(_ other: [UInt8]) { bytes.append(contentsOf: other) }
}

/// Lecture petit-boutiste, avec contrôle des débordements.
struct ByteReader {
    enum Failure: Error {
        case truncated
    }

    let bytes: [UInt8]
    var offset = 0

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var remaining: Int { bytes.count - offset }

    mutating func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset + size <= bytes.count else { throw Failure.truncated }
        var value: T = 0
        for i in 0..<size { value |= T(truncatingIfNeeded: bytes[offset + i]) << (8 * i) }
        offset += size
        return value
    }

    mutating func readFloat() throws -> Float { Float(bitPattern: try read(UInt32.self)) }

    mutating func readCString() throws -> String {
        guard let end = bytes[offset...].firstIndex(of: 0) else { throw Failure.truncated }
        let s = String(decoding: bytes[offset..<end], as: UTF8.self)
        offset = end + 1
        return s
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= bytes.count else { throw Failure.truncated }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }
}

/// Flux zlib (RFC 1950) autour du DEFLATE brut du framework Compression : c'est le format attendu par OpenEXR.
enum Zlib {
    enum Failure: Error {
        case invalidStream
        case sizeMismatch
    }

    /// Renvoie `nil` si la compression ne fait pas gagner de place.
    static func compress(_ input: [UInt8]) -> [UInt8]? {
        guard !input.isEmpty else { return nil }
        let capacity = input.count + input.count / 16 + 1024
        var deflated = [UInt8](repeating: 0, count: capacity)
        let written = input.withUnsafeBufferPointer { src in
            deflated.withUnsafeMutableBufferPointer { dst in
                compression_encode_buffer(dst.baseAddress!, capacity, src.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written + 6 < input.count else { return nil }
        var out: [UInt8] = [0x78, 0x9C]
        out.append(contentsOf: deflated[0..<written])
        let checksum = adler32(input)
        out.append(contentsOf: [UInt8(checksum >> 24), UInt8((checksum >> 16) & 0xFF), UInt8((checksum >> 8) & 0xFF), UInt8(checksum & 0xFF)])
        return out
    }

    static func decompress(_ input: [UInt8], expectedSize: Int) throws -> [UInt8] {
        guard input.count > 6, (Int(input[0]) * 256 + Int(input[1])) % 31 == 0, input[0] & 0x0F == 8 else { throw Failure.invalidStream }
        var out = [UInt8](repeating: 0, count: expectedSize)
        let body = Array(input[2..<(input.count - 4)])
        let written = body.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, expectedSize, src.baseAddress!, body.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw Failure.sizeMismatch }
        return out
    }

    static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        var index = 0
        while index < data.count {
            // Blocs de 5 552 octets : la somme ne peut pas déborder avant le modulo.
            let end = min(index + 5552, data.count)
            while index < end {
                a += UInt32(data[index])
                b += a
                index += 1
            }
            a %= 65521
            b %= 65521
        }
        return (b << 16) | a
    }
}
