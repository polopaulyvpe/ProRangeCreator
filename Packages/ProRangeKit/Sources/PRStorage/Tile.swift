import Foundation

/// Côté d'une tuile en pixels (décision D2). Toutes les tailles de tuile du projet viennent d'ici.
public enum TileSize {
    public static let side = 256
    public static let pixelCount = side * side
}

/// Coordonnées d'une tuile. `level` 0 = résolution de travail ; les niveaux suivants serviront à la pyramide d'affichage (LOD).
public struct TileCoord: Hashable, Sendable, Codable {
    public let level: Int
    public let x: Int
    public let y: Int

    public init(level: Int = 0, x: Int, y: Int) {
        self.level = level
        self.x = x
        self.y = y
    }

    /// Nombre de tuiles par dimension au niveau `level` pour une toile 2:1 de largeur `baseWidth`.
    public static func gridSize(at level: Int, baseWidth: Int) -> (tilesX: Int, tilesY: Int) {
        let width = baseWidth >> level
        let height = width / 2
        return ((width + TileSize.side - 1) / TileSize.side, (height + TileSize.side - 1) / TileSize.side)
    }

    /// Tuile contenant le pixel (x, y) du niveau `level`.
    public static func containing(x: Int, y: Int, level: Int = 0) -> TileCoord {
        TileCoord(level: level, x: x / TileSize.side, y: y / TileSize.side)
    }
}

/// Précision de stockage d'un calque (décision D3).
public enum LayerPixelFormat: String, Codable, Sendable, CaseIterable {
    /// RGBA demi-flottant linéaire prémultiplié : HDR, défaut.
    case rgba16Float
    /// RGBA 8 bits encodé sRGB prémultiplié : moitié moins de mémoire, valeurs écrêtées à [0, 1].
    case rgba8

    public var bytesPerPixel: Int {
        switch self {
        case .rgba16Float: 8
        case .rgba8: 4
        }
    }

    public var bytesPerTile: Int { bytesPerPixel * TileSize.pixelCount }
}

/// État sérialisable d'une tuile : ce que l'historique et le fichier de projet enregistrent.
public enum TileState: Equatable, Sendable {
    /// Tuile jamais peinte (ou revenue à transparent) : n'occupe rien.
    case absent
    /// Tous les pixels identiques : on garde un seul pixel, en octets bruts du format du calque.
    case uniform(Data)
    /// Pixels bruts du format du calque, compressés en LZFSE.
    case packed(Data)

    /// Octets occupés en mémoire par cet état.
    public var byteSize: Int {
        switch self {
        case .absent: 0
        case .uniform(let d), .packed(let d): d.count
        }
    }
}
