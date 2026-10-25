import Foundation

/// Tuiles sur disque, une par fichier, déjà compressées (même représentation que `TileState`).
/// Sert au fichier de projet et, plus tard, au déversement des tuiles inactives quand la mémoire manque.
/// Structure : `{base}/tiles/{level}/{x}_{y}.tile.lzfse` (pixels) ou `{x}_{y}.uniform` (un seul pixel brut).
public struct TileStore: Sendable {
    public let baseURL: URL

    private static let packedExtension = "tile.lzfse"
    private static let uniformExtension = "uniform"

    /// Ouvre ou crée le magasin à `baseURL`.
    public init(baseURL: URL) throws {
        self.baseURL = baseURL
        try FileManager.default.createDirectory(at: baseURL.appendingPathComponent("tiles"), withIntermediateDirectories: true)
    }

    private func levelDirectory(_ level: Int) -> URL {
        baseURL.appendingPathComponent("tiles/\(level)", isDirectory: true)
    }

    private func fileURL(_ coord: TileCoord, extension ext: String) -> URL {
        levelDirectory(coord.level).appendingPathComponent("\(coord.x)_\(coord.y).\(ext)")
    }

    /// Écrit l'état d'une tuile ; `.absent` supprime le fichier.
    public func write(_ state: TileState, at coord: TileCoord) throws {
        try delete(coord)
        switch state {
        case .absent:
            return
        case .uniform(let pixel):
            try FileManager.default.createDirectory(at: levelDirectory(coord.level), withIntermediateDirectories: true)
            try pixel.write(to: fileURL(coord, extension: Self.uniformExtension), options: .atomic)
        case .packed(let data):
            try FileManager.default.createDirectory(at: levelDirectory(coord.level), withIntermediateDirectories: true)
            try data.write(to: fileURL(coord, extension: Self.packedExtension), options: .atomic)
        }
    }

    /// Lit l'état d'une tuile (`.absent` si aucun fichier).
    public func read(_ coord: TileCoord) throws -> TileState {
        let packed = fileURL(coord, extension: Self.packedExtension)
        if FileManager.default.fileExists(atPath: packed.path) {
            return .packed(try Data(contentsOf: packed))
        }
        let uniform = fileURL(coord, extension: Self.uniformExtension)
        if FileManager.default.fileExists(atPath: uniform.path) {
            return .uniform(try Data(contentsOf: uniform))
        }
        return .absent
    }

    public func exists(_ coord: TileCoord) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(coord, extension: Self.packedExtension).path)
            || FileManager.default.fileExists(atPath: fileURL(coord, extension: Self.uniformExtension).path)
    }

    public func delete(_ coord: TileCoord) throws {
        for ext in [Self.packedExtension, Self.uniformExtension] {
            let url = fileURL(coord, extension: ext)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    /// Tuiles présentes à un niveau.
    public func list(level: Int) -> [TileCoord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: levelDirectory(level), includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            let name = url.lastPathComponent
            guard let stem = name.split(separator: ".").first else { return nil }
            let parts = stem.split(separator: "_")
            guard parts.count == 2, let x = Int(parts[0]), let y = Int(parts[1]) else { return nil }
            return TileCoord(level: level, x: x, y: y)
        }
    }
}
