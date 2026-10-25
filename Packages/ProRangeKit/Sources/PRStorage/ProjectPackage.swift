import Foundation
import PRCore

/// Paquet de projet `.prrange` (dossier) :
/// `manifest.json`, `layers/{id}/tiles/0/{x}_{y}.tile.lzfse|.uniform` (via `TileStore`), `journal.bin` (timelapse).
public enum ProjectPackage {
    public static let formatVersion = 2

    public struct Manifest: Codable, Sendable, Equatable {
        public var formatVersion: Int
        public var width: Int
        public var height: Int
        public var tileSize: Int
        public var colorSpace: String
        public var createdAt: Date
        public var modifiedAt: Date
        public var layers: [LayerRecord]
        /// Structure de la pile (v2). Absente en v1 : chaque calque est alors un élément racine.
        public var items: [ItemRecord]?
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
    public static func save(layers: [TiledLayer], to url: URL, createdAt: Date = Date(), items: [ItemRecord]? = nil) throws {
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
            layers: layers.map { LayerRecord(id: $0.id, name: $0.name, format: $0.format, opacity: $0.opacity, isVisible: $0.isVisible) },
            items: items)
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
        guard (1...formatVersion).contains(manifest.formatVersion) else { throw Failure.unsupportedVersion(manifest.formatVersion) }
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

    /// Un élément de la pile dans le manifest v2.
    public struct ItemRecord: Codable, Sendable, Equatable {
        public var id: UUID
        public var isGroup: Bool
        public var name: String
        public var opacity: Float
        public var isVisible: Bool
        public var blendMode: BlendMode
        public var alphaLock: Bool
        public var isClipped: Bool
        public var parent: UUID?
        public var layerID: UUID?
        public var maskID: UUID?
    }

    /// Enregistre une pile complète (calques, masques, groupes, propriétés).
    public static func save(stack: LayerStack, to url: URL, createdAt: Date = Date()) throws {
        let records = stack.items.map { item in
            ItemRecord(id: item.id, isGroup: item.isGroup, name: item.name, opacity: item.opacity, isVisible: item.isVisible,
                       blendMode: item.blendMode, alphaLock: item.alphaLock, isClipped: item.isClipped, parent: item.parent,
                       layerID: item.layer?.id, maskID: item.mask?.id)
        }
        try save(layers: stack.allTiledLayers, to: url, createdAt: createdAt, items: records)
    }

    /// Ouvre une pile (v2), ou construit une pile plate à partir des calques d'un projet v1.
    public static func loadStack(from url: URL) throws -> (manifest: Manifest, stack: LayerStack) {
        let (manifest, layers) = try load(from: url)
        guard let first = layers.first else { throw Failure.noLayers }
        let byID = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) })
        let items: [StackItem]
        if let records = manifest.items {
            items = try records.map { record in
                let kind: StackItem.Kind
                if record.isGroup {
                    kind = .group
                } else {
                    guard let id = record.layerID, let layer = byID[id] else { throw Failure.invalidManifest }
                    kind = .layer(layer)
                }
                var item = StackItem(id: record.id, kind: kind, name: record.name, parent: record.parent)
                item.opacity = record.opacity
                item.isVisible = record.isVisible
                item.blendMode = record.blendMode
                item.alphaLock = record.alphaLock
                item.isClipped = record.isClipped
                item.mask = record.maskID.flatMap { byID[$0] }
                return item
            }
        } else {
            items = layers.map { layer in
                var item = StackItem(kind: .layer(layer), name: layer.name)
                item.opacity = layer.opacity
                item.isVisible = layer.isVisible
                return item
            }
        }
        return (manifest, LayerStack(width: manifest.width, height: manifest.height, format: first.format, items: items))
    }
}
