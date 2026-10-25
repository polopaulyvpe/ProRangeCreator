import Compression
import Foundation

/// Compression LZFSE des tuiles (framework Compression d'Apple).
public enum TileCodec {
    public enum Failure: Error, CustomStringConvertible {
        case compressionFailed
        case decompressionFailed(expected: Int, got: Int)

        public var description: String {
            switch self {
            case .compressionFailed: "Échec compression LZFSE"
            case .decompressionFailed(let expected, let got): "Échec décompression LZFSE (attendu \(expected) octets, obtenu \(got))"
            }
        }
    }

    public static func compress(_ bytes: UnsafeRawBufferPointer) throws -> Data {
        guard let src = bytes.baseAddress, bytes.count > 0 else { return Data() }
        let scratchSize = compression_encode_scratch_buffer_size(COMPRESSION_LZFSE)
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: max(scratchSize, 1), alignment: 16)
        defer { scratch.deallocate() }
        // Des pixels incompressibles peuvent dépasser un peu la taille d'origine.
        let capacity = bytes.count + bytes.count / 16 + 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { dst.deallocate() }
        let written = compression_encode_buffer(dst, capacity, src.assumingMemoryBound(to: UInt8.self), bytes.count,
                                                scratch, COMPRESSION_LZFSE)
        guard written > 0 else { throw Failure.compressionFailed }
        return Data(bytes: dst, count: written)
    }

    public static func compress(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { try compress($0) }
    }

    /// Décompresse vers exactement `expectedSize` octets.
    public static func decompress(_ data: Data, expectedSize: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: expectedSize)
        let scratchSize = compression_decode_scratch_buffer_size(COMPRESSION_LZFSE)
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: max(scratchSize, 1), alignment: 16)
        defer { scratch.deallocate() }
        let written = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, expectedSize,
                                          src.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
                                          scratch, COMPRESSION_LZFSE)
            }
        }
        guard written == expectedSize else { throw Failure.decompressionFailed(expected: expectedSize, got: written) }
        return out
    }
}
