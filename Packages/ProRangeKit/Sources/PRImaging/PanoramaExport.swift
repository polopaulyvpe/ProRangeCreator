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

/// Lit une pile (ou un calque) par bandes de lignes, composée sur le papier et réduite : jamais l'image entière en mémoire.
public struct LayerRowSource {
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let downscale: Int
    /// Tuile composée, ou nil si rien n'y est peint (on met alors `empty`).
    private let tile: (TileCoord) -> [SIMD4<Float>]?
    private let empty: SIMD4<Float>

    /// Toute la pile : modes de fusion, masques, groupes et écrêtage, sur le papier (ou transparent si `paper` est nil).
    public init(stack: LayerStack, downscale: Int = 1, paper: SIMD3<Float>?, space: BlendSpace = .perceptual) {
        precondition(downscale >= 1 && downscale.nonzeroBitCount == 1 && downscale <= TileSize.side, "réduction invalide")
        sourceWidth = stack.width
        sourceHeight = stack.height
        self.downscale = downscale
        let occupied = LayerCompositor.occupiedTiles(stack)
        tile = { coord in
            occupied.contains(coord) ? LayerCompositor.compositeTile(coord, stack: stack, paper: paper, space: space) : nil
        }
        empty = paper.map { SIMD4<Float>($0.x, $0.y, $0.z, 1) } ?? .zero
    }

    /// Un seul calque, en mode Normal.
    public init(layer: TiledLayer, downscale: Int = 1, paper: SIMD3<Float>?) {
        let stack = LayerStack(width: layer.width, height: layer.height, format: layer.format,
                               items: [StackItem(kind: .layer(layer), name: layer.name)])
        self.init(stack: stack, downscale: downscale, paper: paper)
    }

    public var width: Int { sourceWidth / downscale }
    public var height: Int { sourceHeight / downscale }

    public func rows(_ y: Int, _ count: Int) -> [SIMD4<Float>] {
        let side = TileSize.side
        let f = downscale
        let sourceWidth = sourceWidth
        let tilesAcross = (sourceWidth + side - 1) / side
        let sy0 = y * f
        let sy1 = min(sourceHeight, (y + count) * f)
        var source = [SIMD4<Float>](repeating: empty, count: sourceWidth * (sy1 - sy0))
        for ty in (sy0 / side)...((sy1 - 1) / side) {
            for tx in 0..<tilesAcross {
                let coord = TileCoord(x: tx, y: ty)
                guard let pixels = tile(coord) else { continue }
                let rowStart = max(sy0, ty * side)
                let rowEnd = min(sy1, ty * side + side)
                let x0 = tx * side
                let w = min(side, sourceWidth - x0)
                for sy in rowStart..<rowEnd {
                    let src = (sy - ty * side) * side
                    let dst = (sy - sy0) * sourceWidth + x0
                    for i in 0..<w { source[dst + i] = pixels[src + i] }
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
        try export(LayerRowSource(layer: layer, downscale: options.downscale, paper: options.paper), as: format, to: url, progress: progress)
    }

    /// Export de toute la pile (calques visibles, modes, masques, groupes).
    public static func export(_ stack: LayerStack, as format: PanoramaFormat, options: PanoramaExportOptions = .init(),
                              space: BlendSpace = .perceptual, to url: URL, progress: ExportProgress = { _ in true }) throws {
        try export(LayerRowSource(stack: stack, downscale: options.downscale, paper: options.paper, space: space),
                   as: format, to: url, progress: progress)
    }

    static func export(_ source: LayerRowSource, as format: PanoramaFormat, to url: URL, progress: ExportProgress) throws {
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
