import Foundation
import Compression

/// Stockage de tuiles 512×512 compressées LZFSE, chargement paresseux.
/// Chaque tuile = 512×512 pixels RGBA16F = 2 Mo non compressé ≈ 200-400 Ko compressé.
/// Structure sur disque : `{project}.prrange/tiles/{level}/{x}_{y}.tile.lzfse`
public final class TileStore: Sendable {
    public let baseURL: URL
    public let tileSize = 512
    public let maxLevel: Int        // 0 = 16K (134M px), 1 = 8K, 2 = 4K, 3 = 2K, 4 = 1K
    private let queue = DispatchQueue(label: "com.prrange.tilestore", attributes: .concurrent)

    /// Ouvre ou crée le magasin à `baseURL`.
    public init(baseURL: URL, maxLevel: Int = 4) throws {
        self.baseURL = baseURL
        self.maxLevel = maxLevel
        try FileManager.default.createDirectory(at: baseURL.appendingPathComponent("tiles"), withIntermediateDirectories: true)
    }

    /// Chemin du fichier pour une tuile (sans extension).
    private func tilePath(level: Int, x: Int, y: Int) -> URL {
        let levelDir = baseURL.appendingPathComponent("tiles/\(level)", isDirectory: true)
        try? FileManager.default.createDirectory(at: levelDir, withIntermediateDirectories: true)
        return levelDir.appendingPathComponent("\(x)_\(y)")
    }

    /// Chemin du fichier compressé.
    private func compressedPath(level: Int, x: Int, y: Int) -> URL {
        tilePath(level: level, x: x, y: y).appendingPathExtension("tile.lzfse")
    }

    /// Écrit une tuile (RGBA16F, `tileSize × tileSize` pixels, 8 octets/pixel = 2 Mo).
    /// Le buffer doit contenir exactement `tileSize * tileSize * 8` octets.
    public func write(level: Int, x: Int, y: Int, data: Data) throws {
        precondition(data.count == tileSize * tileSize * 8, "Taille de tuile invalide")
        let url = compressedPath(level: level, x: x, y: y)
        let compressed = try compressLZFSE(data)
        try compressed.write(to: url, options: .atomic)
    }

    /// Lit une tuile (retourne `nil` si absente). Décompresse à la volée.
    public func read(level: Int, x: Int, y: Int) -> Data? {
        let url = compressedPath(level: level, x: x, y: y)
        guard let compressed = try? Data(contentsOf: url) else { return nil }
        return try? decompressLZFSE(compressed, expectedSize: tileSize * tileSize * 8)
    }

    /// Vérifie l'existence sans décompresser.
    public func exists(level: Int, x: Int, y: Int) -> Bool {
        FileManager.default.fileExists(atPath: compressedPath(level: level, x: x, y: y).path)
    }

    /// Supprime une tuile.
    public func delete(level: Int, x: Int, y: Int) throws {
        try FileManager.default.removeItem(at: compressedPath(level: level, x: x, y: y))
    }

    /// Liste les tuiles présentes à un niveau.
    public func list(level: Int) -> [(x: Int, y: Int)] {
        let levelDir = baseURL.appendingPathComponent("tiles/\(level)", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: levelDir, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { url in
            let name = url.deletingPathExtension().deletingPathExtension().lastPathComponent // enlève .tile.lzfse
            let parts = name.split(separator: "_")
            guard parts.count == 2, let x = Int(parts[0]), let y = Int(parts[1]) else { return nil }
            return (x, y)
        }
    }

    /// Nombre total de tuiles sur tous les niveaux.
    public var totalTiles: Int {
        var count = 0
        for level in 0...maxLevel {
            count += list(level: level).count
        }
        return count
    }

    // MARK: - Compression LZFSE

    private func compressLZFSE(_ data: Data) throws -> Data {
        return try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let srcBuffer = ptr.bindMemory(to: UInt8.self)
            let maxSize = compression_encode_scratch_buffer_size(COMPRESSION_LZFSE)
            let scratch = UnsafeMutableRawPointer.allocate(byteCount: maxSize, alignment: 16)
            defer { scratch.deallocate() }

            let dstCapacity = data.count + 1024 // marge
            let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
            defer { dstBuffer.deallocate() }

            let written = compression_encode_buffer(
                dstBuffer, dstCapacity,
                srcBuffer.baseAddress!, data.count,
                scratch, maxSize,
                nil, COMPRESSION_LZFSE
            )
            guard written > 0 else { throw TileStoreError.compressionFailed }
            return Data(bytes: dstBuffer, count: written)
        }
    }

    private func decompressLZFSE(_ data: Data, expectedSize: Int) throws -> Data {
        return try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let srcBuffer = ptr.bindMemory(to: UInt8.self)
            let maxSize = compression_decode_scratch_buffer_size(COMPRESSION_LZFSE)
            let scratch = UnsafeMutableRawPointer.allocate(byteCount: maxSize, alignment: 16)
            defer { scratch.deallocate() }

            let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: expectedSize)
            defer { dstBuffer.deallocate() }

            let written = compression_decode_buffer(
                dstBuffer, expectedSize,
                srcBuffer.baseAddress!, data.count,
                scratch, maxSize,
                COMPRESSION_LZFSE
            )
            guard written == expectedSize else { throw TileStoreError.decompressionFailed }
            return Data(bytes: dstBuffer, count: written)
        }
    }

    public enum TileStoreError: Error, CustomStringConvertible {
        case compressionFailed
        case decompressionFailed
        case invalidTileSize

        public var description: String {
            switch self {
            case .compressionFailed: return "Échec compression LZFSE"
            case .decompressionFailed: return "Échec décompression LZFSE"
            case .invalidTileSize: return "Taille de tuile invalide"
            }
        }
    }
}

/// Calcul des coordonnées de tuile pour une résolution donnée.
public struct TileCoord: Hashable, Sendable {
    public let level: Int
    public let x: Int
    public let y: Int

    public init(level: Int, x: Int, y: Int) {
        self.level = level
        self.x = x
        self.y = y
    }

    /// Nombre de tuiles par dimension au niveau `level` pour une toile 2:1.
    public static func gridSize(at level: Int, baseWidth: Int) -> (tilesX: Int, tilesY: Int) {
        let width = baseWidth >> level
        let height = width / 2
        let tilesX = (width + 511) / 512
        let tilesY = (height + 511) / 512
        return (tilesX, tilesY)
    }

    /// Coordonnées de tuile contenant le pixel (x, y) à la résolution de base.
    public static func fromPixel(x: Int, y: Int, level: Int) -> TileCoord {
        let tileX = x / 512
        let tileY = y / 512
        return TileCoord(level: level, x: tileX, y: tileY)
    }

    /// Rectangle de pixels (dans la résolution de base) couvert par cette tuile.
    public func pixelRect(baseWidth: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        let scale = 1 << level
        let x0 = x * 512 * scale
        let y0 = y * 512 * scale
        let w = min(512 * scale, (baseWidth >> level) - x * 512)
        let h = min(512 * scale, ((baseWidth / 2) >> level) - y * 512)
        return (x0, y0, w, h)
    }
}