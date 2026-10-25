import Foundation

/// Paquet de projet `.prrange` (dossier) :
/// `manifest.json`, `layers/{id}/tiles/0/{x}_{y}.tile.lzfse|.uniform` (via `TileStore`), `journal.bin` (timelapse).
public enum ProjectPackage {
    public static let formatVersion = 1

    public struct Manifest: Codable, Sendable, Equatable {
        public var formatVersion: Int
        public var width: Int
        public var height: Int
        public var tileSize: Int
        public var colorSpace: String
        public var createdAt: Date
        public var modifiedAt: Date
        public var layers: [LayerRecord]
    }

    public struct LayerRecord: Codable, Sendable, Equatable {
        public var id: UUID
        public var name: String
        public var format: LayerPixelFormat
        public var opacity: Float
        public var isVisible: Bool
    }

    public enum Failure: Error, CustomStringConvertible {
        case invalidManifest
        case unsupportedVersion(Int)
        case tileSizeMismatch(Int)
        case noLayers

        public var description: String {
            switch self {
            case .invalidManifest: "Manifest invalide ou manquant"
            case .unsupportedVersion(let v): "Version de projet non gérée : \(v)"
            case .tileSizeMismatch(let s): "Taille de tuile du projet (\(s)) différente de celle de l'app (\(TileSize.side))"
            case .noLayers: "Projet sans calque"
            }
        }
    }

    public static func journalURL(in package: URL) -> URL { package.appendingPathComponent("journal.bin") }

    /// Enregistre les calques. Écrit dans un dossier temporaire puis remplace l'ancien paquet (le journal est conservé).
    public static func save(layers: [TiledLayer], to url: URL, createdAt: Date = Date()) throws {
        guard let first = layers.first else { throw Failure.noLayers }
        let fm = FileManager.default
        let staging = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).saving")
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        for layer in layers {
            let store = try TileStore(baseURL: staging.appendingPathComponent("layers/\(layer.id.uuidString)"))
            for coord in layer.storedTiles { try store.write(layer.state(of: coord), at: coord) }
        }
        let manifest = Manifest(
            formatVersion: formatVersion, width: first.width, height: first.height, tileSize: TileSize.side,
            colorSpace: "linear-display-p3-premultiplied", createdAt: createdAt, modifiedAt: Date(),
            layers: layers.map { LayerRecord(id: $0.id, name: $0.name, format: $0.format, opacity: $0.opacity, isVisible: $0.isVisible) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)

        if fm.fileExists(atPath: journalURL(in: url).path) {
            try fm.copyItem(at: journalURL(in: url), to: journalURL(in: staging))
        }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: url)
        }
    }

    public static func load(from url: URL) throws -> (manifest: Manifest, layers: [TiledLayer]) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")),
              let manifest = try? decoder.decode(Manifest.self, from: data) else { throw Failure.invalidManifest }
        guard manifest.formatVersion == formatVersion else { throw Failure.unsupportedVersion(manifest.formatVersion) }
        guard manifest.tileSize == TileSize.side else { throw Failure.tileSizeMismatch(manifest.tileSize) }

        let layers = try manifest.layers.map { record -> TiledLayer in
            let layer = TiledLayer(id: record.id, name: record.name, width: manifest.width, height: manifest.height, format: record.format)
            layer.opacity = record.opacity
            layer.isVisible = record.isVisible
            let store = try TileStore(baseURL: url.appendingPathComponent("layers/\(record.id.uuidString)"))
            for coord in store.list(level: 0) {
                let state = try store.read(coord)
                if case .packed(let d) = state {
                    // Valide la tuile dès le chargement, pour ne jamais échouer plus tard en pleine peinture.
                    _ = try TileCodec.decompress(d, expectedSize: record.format.bytesPerTile)
                }
                layer.restore(state, at: coord)
            }
            return layer
        }
        return (manifest, layers)
    }
}
