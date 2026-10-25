import Foundation
import PRCore

/// Calque équirectangulaire en tuiles éparses.
/// - Une tuile jamais peinte n'existe pas ; une tuile uniforme ne garde qu'un pixel.
/// - Les tuiles inactives peuvent être recompressées en mémoire (`compact`).
/// - Toute écriture passe par `takePixels` / `putPixels`, qui enregistrent l'état d'avant pour l'historique.
/// Pas thread-safe : un calque appartient à un seul contexte d'exécution.
public final class TiledLayer {
    public let id: UUID
    public var name: String
    public let width: Int
    public let height: Int
    public let format: LayerPixelFormat
    public let geometry: EquirectGeometry
    public var opacity: Float = 1
    public var isVisible = true

    private enum Content {
        case uniform(Data)
        case pixels([UInt8])
        case packed(Data)
    }

    private var tiles: [TileCoord: Content] = [:]
    /// États d'avant des tuiles touchées pendant l'opération en cours.
    private var recording: [TileCoord: TileState]?

    public init(id: UUID = UUID(), name: String, width: Int, height: Int, format: LayerPixelFormat = .rgba16Float) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.format = format
        geometry = EquirectGeometry(width: width, height: height)
    }

    public var tilesAcross: Int { (width + TileSize.side - 1) / TileSize.side }
    public var tilesDown: Int { (height + TileSize.side - 1) / TileSize.side }

    /// Tuiles réellement stockées (les autres sont transparentes).
    public var storedTiles: [TileCoord] { Array(tiles.keys) }

    /// Octets occupés en mémoire par les pixels de ce calque.
    public var residentBytes: Int {
        tiles.values.reduce(0) { sum, content in
            switch content {
            case .uniform(let d), .packed(let d): sum + d.count
            case .pixels(let p): sum + p.count
            }
        }
    }

    // MARK: - Lecture

    public func pixel(x: Int, y: Int) -> SIMD4<Float> {
        let coord = TileCoord.containing(x: x, y: y)
        let index = (y % TileSize.side) * TileSize.side + (x % TileSize.side)
        switch tiles[coord] {
        case nil:
            return .zero
        case .uniform(let d):
            return d.withUnsafeBytes { Self.read($0.baseAddress!, 0, format) }
        case .pixels(let p):
            return p.withUnsafeBytes { Self.read($0.baseAddress!, index, format) }
        case .packed(let d):
            // Lecture répétée probable : on garde la tuile décompressée (même contenu, pas d'historique).
            let p = Self.unpack(d, format: format)
            tiles[coord] = .pixels(p)
            return p.withUnsafeBytes { Self.read($0.baseAddress!, index, format) }
        }
    }

    /// Pixels bruts d'une tuile, dans le format du calque (zéros si absente).
    public func tileBytes(_ coord: TileCoord) -> [UInt8] {
        switch tiles[coord] {
        case nil: [UInt8](repeating: 0, count: format.bytesPerTile)
        case .uniform(let d): Self.repeated(d)
        case .pixels(let p): p
        case .packed(let d): Self.unpack(d, format: format)
        }
    }

    /// État sérialisable d'une tuile.
    public func state(of coord: TileCoord) -> TileState {
        switch tiles[coord] {
        case nil: .absent
        case .uniform(let d): .uniform(d)
        case .pixels(let p): .packed(Self.pack(p))
        case .packed(let d): .packed(d)
        }
    }

    /// Remet une tuile dans un état donné, sans l'enregistrer dans l'historique (annulation, chargement).
    public func restore(_ state: TileState, at coord: TileCoord) {
        switch state {
        case .absent: tiles[coord] = nil
        case .uniform(let d): tiles[coord] = .uniform(d)
        case .packed(let d): tiles[coord] = .packed(d)
        }
    }

    // MARK: - Écriture

    /// Peint un dab sphérique. Renvoie les tuiles modifiées.
    @discardableResult
    public func stamp(_ dab: SphericalDab) -> Set<TileCoord> {
        let evaluator = DabEvaluator(dab, pixelAngle: geometry.pixelAngle)
        let span = evaluator.span(in: geometry)
        let side = TileSize.side
        var touched = Set<TileCoord>()
        for columns in span.columns {
            for ty in (span.rows.lowerBound / side)...(span.rows.upperBound / side) {
                for tx in (columns.lowerBound / side)...(columns.upperBound / side) {
                    let xs = max(columns.lowerBound, tx * side)...min(columns.upperBound, tx * side + side - 1)
                    let ys = max(span.rows.lowerBound, ty * side)...min(span.rows.upperBound, ty * side + side - 1)
                    let coord = TileCoord(x: tx, y: ty)
                    if stampTile(coord, xs: xs, ys: ys, evaluator: evaluator) { touched.insert(coord) }
                }
            }
        }
        return touched
    }

    /// Remplit tout le calque d'une valeur (RGB linéaire prémultiplié). Zéro vide le calque.
    public func fill(_ value: SIMD4<Float>) {
        let pixel = Self.encode(value, format: format)
        let isZero = pixel.allSatisfy { $0 == 0 }
        for ty in 0..<tilesDown {
            for tx in 0..<tilesAcross {
                let coord = TileCoord(x: tx, y: ty)
                willModify(coord)
                tiles[coord] = isZero ? nil : .uniform(pixel)
            }
        }
    }

    /// Recompresse en mémoire les tuiles décompressées, sauf celles de `keep` (zone de travail en cours).
    public func compact(keeping keep: Set<TileCoord> = []) {
        for (coord, content) in tiles where !keep.contains(coord) {
            if case .pixels(let p) = content { tiles[coord] = .packed(Self.pack(p)) }
        }
    }

    // MARK: - Historique

    /// Commence à enregistrer les tuiles touchées.
    public func beginOperation() {
        precondition(recording == nil, "opération déjà en cours")
        recording = [:]
    }

    /// Termine l'enregistrement et renvoie les deltas (avant/après) des tuiles réellement modifiées.
    public func endOperation() -> [TileDelta] {
        guard let before = recording else { return [] }
        recording = nil
        return before
            .compactMap { coord, old -> TileDelta? in
                let new = state(of: coord)
                return old == new ? nil : TileDelta(coord: coord, before: old, after: new)
            }
            .sorted { ($0.coord.y, $0.coord.x) < ($1.coord.y, $1.coord.x) }
    }

    private func willModify(_ coord: TileCoord) {
        guard recording != nil, recording?[coord] == nil else { return }
        recording?[coord] = state(of: coord)
    }

    // MARK: - Tuiles

    private func stampTile(_ coord: TileCoord, xs: ClosedRange<Int>, ys: ClosedRange<Int>, evaluator: DabEvaluator) -> Bool {
        // Couverture d'abord : une tuile que le dab ne touche pas n'est ni créée ni enregistrée.
        var coverage = [Float](repeating: 0, count: xs.count * ys.count)
        var any = false
        var i = 0
        for y in ys {
            for x in xs {
                let a = evaluator.coverage(at: geometry.direction(x: x, y: y))
                coverage[i] = a
                if a > 0 { any = true }
                i += 1
            }
        }
        guard any else { return false }

        let side = TileSize.side
        let format = format
        let color = evaluator.dab.color
        var pixels = takePixels(coord)
        pixels.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            var i = 0
            for y in ys {
                let row = (y - coord.y * side) * side
                for x in xs {
                    let a = coverage[i]
                    i += 1
                    if a <= 0 { continue }
                    let index = row + (x - coord.x * side)
                    var p = Self.read(UnsafeRawPointer(base), index, format)
                    SphericalRasterizer.blend(color, coverage: a, into: &p)
                    Self.write(base, index, p, format)
                }
            }
        }
        putPixels(pixels, at: coord)
        return true
    }

    /// Sort une tuile du dictionnaire sous forme de pixels modifiables (copie unique, pas de copie à l'écriture).
    private func takePixels(_ coord: TileCoord) -> [UInt8] {
        willModify(coord)
        switch tiles.removeValue(forKey: coord) {
        case nil: return [UInt8](repeating: 0, count: format.bytesPerTile)
        case .uniform(let d): return Self.repeated(d)
        case .pixels(let p): return p
        case .packed(let d): return Self.unpack(d, format: format)
        }
    }

    /// Range une tuile en la normalisant : uniforme → un pixel, transparente → supprimée.
    private func putPixels(_ pixels: [UInt8], at coord: TileCoord) {
        let bpp = format.bytesPerPixel
        let uniform = pixels.withUnsafeBytes { raw -> Bool in
            let base = raw.baseAddress!
            for offset in stride(from: bpp, to: raw.count, by: bpp) where memcmp(base, base + offset, bpp) != 0 {
                return false
            }
            return true
        }
        guard uniform else {
            tiles[coord] = .pixels(pixels)
            return
        }
        let first = Data(pixels[0..<bpp])
        tiles[coord] = first.allSatisfy { $0 == 0 } ? nil : .uniform(first)
    }

    // MARK: - Encodage des pixels

    @inline(__always)
    static func read(_ raw: UnsafeRawPointer, _ index: Int, _ format: LayerPixelFormat) -> SIMD4<Float> {
        switch format {
        case .rgba16Float:
            let o = index * 8
            return SIMD4<Float>(Float(raw.loadUnaligned(fromByteOffset: o, as: Float16.self)),
                                Float(raw.loadUnaligned(fromByteOffset: o + 2, as: Float16.self)),
                                Float(raw.loadUnaligned(fromByteOffset: o + 4, as: Float16.self)),
                                Float(raw.loadUnaligned(fromByteOffset: o + 6, as: Float16.self)))
        case .rgba8:
            let o = index * 4
            let r = Float(raw.load(fromByteOffset: o, as: UInt8.self)) / 255
            let g = Float(raw.load(fromByteOffset: o + 1, as: UInt8.self)) / 255
            let b = Float(raw.load(fromByteOffset: o + 2, as: UInt8.self)) / 255
            let a = Float(raw.load(fromByteOffset: o + 3, as: UInt8.self)) / 255
            return SIMD4<Float>(ColorTransfer.toLinear(r), ColorTransfer.toLinear(g), ColorTransfer.toLinear(b), a)
        }
    }

    @inline(__always)
    static func write(_ raw: UnsafeMutableRawPointer, _ index: Int, _ value: SIMD4<Float>, _ format: LayerPixelFormat) {
        switch format {
        case .rgba16Float:
            let o = index * 8
            raw.storeBytes(of: Float16(value.x), toByteOffset: o, as: Float16.self)
            raw.storeBytes(of: Float16(value.y), toByteOffset: o + 2, as: Float16.self)
            raw.storeBytes(of: Float16(value.z), toByteOffset: o + 4, as: Float16.self)
            raw.storeBytes(of: Float16(value.w), toByteOffset: o + 6, as: Float16.self)
        case .rgba8:
            let o = index * 4
            raw.storeBytes(of: ColorTransfer.encode8(value.x), toByteOffset: o, as: UInt8.self)
            raw.storeBytes(of: ColorTransfer.encode8(value.y), toByteOffset: o + 1, as: UInt8.self)
            raw.storeBytes(of: ColorTransfer.encode8(value.z), toByteOffset: o + 2, as: UInt8.self)
            raw.storeBytes(of: UInt8(min(1, max(0, value.w)) * 255 + 0.5), toByteOffset: o + 3, as: UInt8.self)
        }
    }

    /// Un pixel encodé dans le format donné.
    public static func encode(_ value: SIMD4<Float>, format: LayerPixelFormat) -> Data {
        var bytes = [UInt8](repeating: 0, count: format.bytesPerPixel)
        bytes.withUnsafeMutableBytes { write($0.baseAddress!, 0, value, format) }
        return Data(bytes)
    }

    private static func repeated(_ pixel: Data) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(pixel.count * TileSize.pixelCount)
        for _ in 0..<TileSize.pixelCount { out.append(contentsOf: pixel) }
        return out
    }

    private static func pack(_ pixels: [UInt8]) -> Data {
        // Ne peut échouer qu'en cas d'allocation impossible : on préfère s'arrêter que corrompre l'historique.
        pixels.withUnsafeBytes { try! TileCodec.compress($0) }
    }

    private static func unpack(_ data: Data, format: LayerPixelFormat) -> [UInt8] {
        // Données produites par `pack` (ou validées au chargement du projet).
        try! TileCodec.decompress(data, expectedSize: format.bytesPerTile)
    }
}
