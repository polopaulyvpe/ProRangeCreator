import Foundation
import PRCore
import PRStorage
import simd

/// Orientation à l'export : rotation autour de la verticale (lacet) et miroir horizontal.
/// Le lacet décale le contenu vers la droite de l'image (u croissant) ; en équirectangulaire il est arrondi au pixel,
/// ce qui garde l'export sans perte.
public struct ExportOrientation: Equatable, Sendable {
    public var yawDegrees: Double
    public var flipHorizontal: Bool

    public init(yawDegrees: Double = 0, flipHorizontal: Bool = false) {
        self.yawDegrees = yawDegrees
        self.flipHorizontal = flipHorizontal
    }

    public static let identity = ExportOrientation()

    /// u de l'app correspondant à un u exporté.
    func appU(_ u: Double) -> Double {
        (flipHorizontal ? 1 - u : u) - yawDegrees / 360
    }

    /// Décalage entier (en pixels) d'une image équirectangulaire de largeur `width`.
    func pixelShift(width: Int) -> Int {
        Int((yawDegrees / 360 * Double(width)).rounded())
    }
}

/// Préréglages : le « devant » de l'app (u = 0,5, ce que montre la vue à l'ouverture) arrive face à l'axe avant
/// du logiciel cible. Conventions lues dans les shaders de chaque logiciel (voir ARCHITECTURE.md), à vérifier sur place.
public enum OrientationPreset: String, CaseIterable, Sendable {
    /// Blender : u = 0,5 − atan2(y, x)/2π ; la vue de face (pavé 1) regarde +Y, qui tombe en u = 0,25.
    case blender
    /// Unreal Engine 5 : avant = +X, au centre de l'image long-lat.
    case unreal
    /// Unity : u = 0,5 − atan2(z, x)/2π (Skybox/Panoramic) ; l'avant +Z tombe en u = 0,25.
    case unity
    /// Aucune transformation : l'image telle que la montre la vue dépliée.
    case generic

    public var label: String {
        switch self {
        case .blender: "Blender"
        case .unreal: "Unreal Engine 5"
        case .unity: "Unity"
        case .generic: "Générique"
        }
    }

    public var orientation: ExportOrientation {
        switch self {
        case .blender, .unity: ExportOrientation(yawDegrees: -90)
        case .unreal, .generic: .identity
        }
    }
}

/// Disposition de l'image exportée.
public enum PanoramaLayout: String, CaseIterable, Sendable {
    case equirectangular
    /// Six fichiers carrés, suffixes _px, _nx, _py, _ny, _pz, _nz.
    case cubeFaces
    /// Croix horizontale 4 × 3 (+Y en haut, −X +Z +X −Z au milieu, −Y en bas).
    case cubeCross
    /// Bande 6 × 1 dans l'ordre +X −X +Y −Y +Z −Z (« 6 frames layout » d'Unity, ordre des tableaux de cubemap).
    case cubeStrip

    public var label: String {
        switch self {
        case .equirectangular: "Équirectangulaire"
        case .cubeFaces: "Cubemap : 6 fichiers"
        case .cubeCross: "Cubemap : croix"
        case .cubeStrip: "Cubemap : bande 6 × 1"
        }
    }

    public var isCubemap: Bool { self != .equirectangular }
}

/// Faces de cubemap, convention OpenGL / DirectX : (s, t) avec t vers le bas de la face.
public enum CubemapFace: Int, CaseIterable, Sendable {
    case px, nx, py, ny, pz, nz

    public var suffix: String {
        switch self {
        case .px: "px"
        case .nx: "nx"
        case .py: "py"
        case .ny: "ny"
        case .pz: "pz"
        case .nz: "nz"
        }
    }

    /// Direction (non normalisée) du point (a, b) de la face, a et b dans [-1, 1], a vers la droite, b vers le bas.
    public func direction(a: Double, b: Double) -> Vec3 {
        switch self {
        case .px: [1, -b, -a]
        case .nx: [-1, -b, a]
        case .py: [a, 1, b]
        case .ny: [a, -1, -b]
        case .pz: [a, -b, 1]
        case .nz: [-a, -b, -1]
        }
    }

    /// Face et coordonnées (a, b) d'une direction : inverse de `direction(a:b:)`.
    public static func locate(_ d: Vec3) -> (face: CubemapFace, a: Double, b: Double) {
        let m = simd_abs(d)
        if m.x >= m.y && m.x >= m.z {
            return d.x > 0 ? (.px, -d.z / m.x, -d.y / m.x) : (.nx, d.z / m.x, -d.y / m.x)
        }
        if m.y >= m.z {
            return d.y > 0 ? (.py, d.x / m.y, d.z / m.y) : (.ny, d.x / m.y, -d.z / m.y)
        }
        return d.z > 0 ? (.pz, d.x / m.z, -d.y / m.z) : (.nz, -d.x / m.z, -d.y / m.z)
    }

    /// Position (colonne, ligne) dans la croix 4 × 3.
    var crossCell: (Int, Int) {
        switch self {
        case .py: (1, 0)
        case .nx: (0, 1)
        case .pz: (1, 1)
        case .px: (2, 1)
        case .nz: (3, 1)
        case .ny: (1, 2)
        }
    }
}

/// Accès aléatoire bilinéaire au composite pleine résolution, avec un petit cache de tuiles (le cubemap
/// lit l'équirectangulaire dans tous les sens : impossible de le servir par bandes de lignes).
final class CompositeSampler {
    private let source: LayerRowSource
    private let capacity: Int
    private var cache: [TileCoord: [SIMD4<Float>]] = [:]
    private var order: [TileCoord] = []
    private var lastCoord = TileCoord(x: -1, y: -1)
    private var lastTile: [SIMD4<Float>]?
    private let empty: SIMD4<Float>
    private let width: Int
    private let height: Int

    init(_ source: LayerRowSource, capacity: Int = 96) {
        self.source = source
        self.capacity = capacity
        empty = source.emptyValue
        width = source.sourceWidth
        height = source.sourceHeight
    }

    private func pixel(_ x: Int, _ y: Int) -> SIMD4<Float> {
        let side = TileSize.side
        let coord = TileCoord(x: x / side, y: y / side)
        if coord != lastCoord {
            lastCoord = coord
            if let cached = cache[coord] {
                lastTile = cached
            } else {
                let tile = source.compositeTile(coord)
                if cache.count >= capacity, !order.isEmpty { cache[order.removeFirst()] = nil }
                if let tile {
                    cache[coord] = tile
                    order.append(coord)
                }
                lastTile = tile
            }
        }
        guard let tile = lastTile else { return empty }
        return tile[(y % side) * side + x % side]
    }

    /// Valeur en coordonnées pixel continues (centre du texel (x, y) en (x + 0,5, y + 0,5)), bouclée en x.
    func sample(_ px: Double, _ py: Double) -> SIMD4<Float> {
        let x = px - 0.5
        let y = min(Double(height - 1), max(0, py - 0.5))
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let fx = Float(x - Double(x0))
        let fy = Float(y - Double(y0))
        let xa = ((x0 % width) + width) % width
        let xb = (xa + 1) % width
        let yb = min(height - 1, y0 + 1)
        let top = pixel(xa, y0) * (1 - fx) + pixel(xb, y0) * fx
        let bottom = pixel(xa, yb) * (1 - fx) + pixel(xb, yb) * fx
        return top * (1 - fy) + bottom * fy
    }

    func sample(direction d: Vec3, orientation: ExportOrientation) -> SIMD4<Float> {
        let uv = Equirect.uv(from: d)
        var u = orientation.appU(uv.x)
        u -= floor(u)
        return sample(u * Double(width), uv.y * Double(height))
    }
}

/// Sources de lignes pour chaque disposition (équirectangulaire orientée, face, croix, bande).
enum LayoutSource {
    /// Équirectangulaire avec décalage entier et miroir, appliqués ligne par ligne : sans perte.
    static func equirectangular(_ source: LayerRowSource, orientation: ExportOrientation, upscale: Int = 1) -> (Int, Int, RowProvider) {
        let base: (Int, Int, RowProvider) = upscale > 1
            ? upscaled(source, factor: upscale)
            : (source.width, source.height, { y, count in source.rows(y, count) })
        let (width, height, baseRows) = base
        let shift = ((orientation.pixelShift(width: width) % width) + width) % width
        let flip = orientation.flipHorizontal
        let rows: RowProvider = { y, count in
            let band = try baseRows(y, count)
            guard shift != 0 || flip else { return band }
            var out = band
            for row in 0..<count {
                let base = row * width
                for x in 0..<width {
                    let shown = flip ? width - 1 - x : x
                    out[base + x] = band[base + ((shown - shift) % width + width) % width]
                }
            }
            return out
        }
        return (width, height, rows)
    }

    /// Agrandissement bilinéaire (bouclé en x, borné en y), en flux : chaque bande lit les lignes source dont elle a besoin.
    /// Une image plus grande, sans détail en plus que la toile.
    static func upscaled(_ source: LayerRowSource, factor: Int) -> (Int, Int, RowProvider) {
        let sw = source.width, sh = source.height
        let w = sw * factor, h = sh * factor
        let f = Double(factor)
        let rows: RowProvider = { y, count in
            func src(_ o: Int) -> Double { (Double(o) + 0.5) / f - 0.5 }
            let a = max(0, Int(floor(src(y))))
            let b = min(sh - 1, Int(floor(src(y + count - 1))) + 1)
            let band = source.rows(a, b - a + 1)
            var out = [SIMD4<Float>](repeating: .zero, count: w * count)
            for r in 0..<count {
                let sy = min(Double(sh - 1), max(0, src(y + r)))
                let y0 = Int(floor(sy))
                let fy = Float(sy - Double(y0))
                let y1 = min(sh - 1, y0 + 1)
                let r0 = (y0 - a) * sw, r1 = (y1 - a) * sw
                for x in 0..<w {
                    let sx = src(x)
                    let x0 = floor(sx)
                    let fx = Float(sx - x0)
                    let xa = ((Int(x0) % sw) + sw) % sw
                    let xb = (xa + 1) % sw
                    let top = band[r0 + xa] * (1 - fx) + band[r0 + xb] * fx
                    let bottom = band[r1 + xa] * (1 - fx) + band[r1 + xb] * fx
                    out[r * w + x] = top * (1 - fy) + bottom * fy
                }
            }
            return out
        }
        return (w, h, rows)
    }

    /// Côté d'une face : un quart de la largeur du panorama réduit.
    static func faceSize(_ source: LayerRowSource) -> Int { max(1, source.sourceWidth / 4 / source.downscale) }

    /// Lignes [y, y + count) d'une face, suréchantillonnées (n × n points par pixel, n = réduction plafonnée à 4).
    static func faceRows(_ face: CubemapFace, sampler: CompositeSampler, size: Int, supersample: Int,
                         orientation: ExportOrientation, y: Int, count: Int) -> [SIMD4<Float>] {
        var out = [SIMD4<Float>](repeating: .zero, count: size * count)
        let n = supersample
        let weight = 1 / Float(n * n)
        for row in 0..<count {
            for x in 0..<size {
                var sum = SIMD4<Float>.zero
                for sy in 0..<n {
                    let b = 2 * (Double(y + row) + (Double(sy) + 0.5) / Double(n)) / Double(size) - 1
                    for sx in 0..<n {
                        let a = 2 * (Double(x) + (Double(sx) + 0.5) / Double(n)) / Double(size) - 1
                        sum += sampler.sample(direction: simd_normalize(face.direction(a: a, b: b)), orientation: orientation)
                    }
                }
                out[row * size + x] = sum * weight
            }
        }
        return out
    }

    static func face(_ face: CubemapFace, _ source: LayerRowSource, orientation: ExportOrientation) -> (Int, Int, RowProvider) {
        let sampler = CompositeSampler(source)
        let size = faceSize(source)
        let n = min(4, source.downscale)
        return (size, size, { y, count in
            faceRows(face, sampler: sampler, size: size, supersample: n, orientation: orientation, y: y, count: count)
        })
    }

    /// Croix 4 × 3 ou bande 6 × 1 ; les cases vides sont transparentes (noires sans alpha).
    static func assembled(_ layout: PanoramaLayout, _ source: LayerRowSource, orientation: ExportOrientation) -> (Int, Int, RowProvider) {
        let sampler = CompositeSampler(source)
        let size = faceSize(source)
        let n = min(4, source.downscale)
        let cells: [(CubemapFace, Int, Int)] = layout == .cubeCross
            ? CubemapFace.allCases.map { ($0, $0.crossCell.0, $0.crossCell.1) }
            : CubemapFace.allCases.map { ($0, $0.rawValue, 0) }
        let columns = layout == .cubeCross ? 4 : 6
        let width = columns * size
        let height = (layout == .cubeCross ? 3 : 1) * size
        return (width, height, { y, count in
            var out = [SIMD4<Float>](repeating: .zero, count: width * count)
            var row = 0
            while row < count {
                let gy = y + row
                let cellRow = gy / size
                let lines = min(count - row, (cellRow + 1) * size - gy)
                for (face, column, line) in cells where line == cellRow {
                    let pixels = faceRows(face, sampler: sampler, size: size, supersample: n, orientation: orientation,
                                          y: gy - cellRow * size, count: lines)
                    for r in 0..<lines {
                        for x in 0..<size { out[(row + r) * width + column * size + x] = pixels[r * size + x] }
                    }
                }
                row += lines
            }
            return out
        })
    }
}
