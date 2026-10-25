import Foundation
import PRCore
import PRStorage

/// Format d'export choisi à chaque fois.
public enum PanoramaFormat: Hashable, Sendable {
    case exr(EXRPixelType, EXRCompression, includeAlpha: Bool)
    case hdr

    public var fileExtension: String {
        switch self {
        case .exr: "exr"
        case .hdr: "hdr"
        }
    }
}

public struct PanoramaExportOptions: Sendable {
    /// Réduction de résolution (puissance de 2) : 1 = taille du projet.
    public var downscale: Int
    /// Papier composé sous le calque (blanc par défaut) ; `nil` = fond transparent.
    public var paper: SIMD3<Float>?

    public init(downscale: Int = 1, paper: SIMD3<Float>? = [1, 1, 1]) {
        self.downscale = downscale
        self.paper = paper
    }
}

/// Lit un calque par bandes de lignes, réduit et composé sur le papier : jamais l'image entière en mémoire.
public struct LayerRowSource {
    public let layer: TiledLayer
    public let downscale: Int
    public let paper: SIMD3<Float>?

    public init(layer: TiledLayer, downscale: Int = 1, paper: SIMD3<Float>?) {
        precondition(downscale >= 1 && downscale.nonzeroBitCount == 1 && downscale <= TileSize.side, "réduction invalide")
        self.layer = layer
        self.downscale = downscale
        self.paper = paper
    }

    public var width: Int { layer.width / downscale }
    public var height: Int { layer.height / downscale }

    public func rows(_ y: Int, _ count: Int) -> [SIMD4<Float>] {
        let side = TileSize.side
        let f = downscale
        let sourceWidth = layer.width
        let sy0 = y * f
        let sy1 = min(layer.height, (y + count) * f)
        var source = [SIMD4<Float>](repeating: .zero, count: sourceWidth * (sy1 - sy0))
        for ty in (sy0 / side)...((sy1 - 1) / side) {
            for tx in 0..<layer.tilesAcross {
                let coord = TileCoord(x: tx, y: ty)
                guard layer.isStored(coord) else { continue }
                let tile = layer.tileFloatPixels(coord)
                let rowStart = max(sy0, ty * side)
                let rowEnd = min(sy1, ty * side + side)
                let x0 = tx * side
                let w = min(side, sourceWidth - x0)
                for sy in rowStart..<rowEnd {
                    let src = (sy - ty * side) * side
                    let dst = (sy - sy0) * sourceWidth + x0
                    for i in 0..<w { source[dst + i] = tile[src + i] }
                }
            }
        }

        let outWidth = sourceWidth / f
        var out = [SIMD4<Float>](repeating: .zero, count: outWidth * count)
        let weight = 1 / Float(f * f)
        for oy in 0..<count {
            for ox in 0..<outWidth {
                var p = SIMD4<Float>.zero
                if f == 1 {
                    p = source[oy * sourceWidth + ox]
                } else {
                    for dy in 0..<f {
                        let row = (oy * f + dy) * sourceWidth + ox * f
                        for dx in 0..<f { p += source[row + dx] }
                    }
                    p *= weight
                }
                if let paper {
                    let rgb = SIMD3<Float>(p.x, p.y, p.z) + paper * (1 - p.w)
                    p = SIMD4<Float>(rgb.x, rgb.y, rgb.z, 1)
                }
                out[oy * outWidth + ox] = p
            }
        }
        return out
    }
}

/// Export d'un calque en EXR ou HDR, en flux par bandes de 256 lignes, avec progression et annulation.
/// Le fichier n'apparaît qu'une fois complet (écriture dans un fichier temporaire voisin).
public enum PanoramaExporter {
    public static func export(_ layer: TiledLayer, as format: PanoramaFormat, options: PanoramaExportOptions = .init(),
                              to url: URL, progress: ExportProgress = { _ in true }) throws {
        let source = LayerRowSource(layer: layer, downscale: options.downscale, paper: options.paper)
        let partial = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).partial")
        switch format {
        case let .exr(pixelType, compression, includeAlpha):
            try EXRWriter.write(to: partial, width: source.width, height: source.height, pixelType: pixelType,
                                compression: compression, includeAlpha: includeAlpha, rows: source.rows, progress: progress)
        case .hdr:
            try RadianceWriter.write(to: partial, width: source.width, height: source.height, rows: source.rows, progress: progress)
        }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: partial, to: url)
    }

    /// PSNR (dB) entre deux images de même taille, sur RGB : sert à vérifier un export relu.
    public static func psnr(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>], peak: Float = 1) -> Double {
        precondition(a.count == b.count)
        var sum = 0.0
        for i in a.indices {
            let d = a[i] - b[i]
            sum += Double((d * d).sum())
        }
        let mse = sum / Double(a.count * 3)
        return mse == 0 ? .infinity : 10 * log10(Double(peak * peak) / mse)
    }
}
