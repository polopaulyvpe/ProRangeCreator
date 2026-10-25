import Foundation
import PRCore
import simd

/// Lecture bilinéaire d'un calque en n'importe quelle direction (longitude bouclée, latitude bornée).
/// Garde les tuiles décodées en cache : à utiliser sur un calque qui ne change pas pendant la lecture (instantané).
public final class LayerSampler {
    public let layer: TiledLayer
    private var cache: [TileCoord: [SIMD4<Float>]] = [:]
    private let zeroTile = [SIMD4<Float>](repeating: .zero, count: TileSize.pixelCount)
    // Dernière tuile lue : les accès successifs tombent presque toujours dans la même.
    private var lastCoord = TileCoord(x: -1, y: -1)
    private var lastTile: [SIMD4<Float>] = []

    public init(_ layer: TiledLayer) {
        self.layer = layer
    }

    public func texel(_ x: Int, _ y: Int) -> SIMD4<Float> {
        let w = layer.width
        let xx = ((x % w) + w) % w
        let yy = min(layer.height - 1, max(0, y))
        let coord = TileCoord.containing(x: xx, y: yy)
        if coord != lastCoord {
            if let cached = cache[coord] {
                lastTile = cached
            } else {
                lastTile = layer.isStored(coord) ? layer.tileFloatPixels(coord) : zeroTile
                cache[coord] = lastTile
            }
            lastCoord = coord
        }
        return lastTile[(yy % TileSize.side) * TileSize.side + xx % TileSize.side]
    }

    /// Valeur bilinéaire en coordonnées pixel continues (centre du texel (x, y) = (x + 0,5, y + 0,5)).
    public func sample(pixel p: SIMD2<Double>) -> SIMD4<Float> {
        let fx = p.x - 0.5
        let fy = p.y - 0.5
        let x0 = Int(floor(fx))
        let y0 = Int(floor(fy))
        let tx = Float(fx - Double(x0))
        let ty = Float(fy - Double(y0))
        let top = texel(x0, y0) * (1 - tx) + texel(x0 + 1, y0) * tx
        let bottom = texel(x0, y0 + 1) * (1 - tx) + texel(x0 + 1, y0 + 1) * tx
        return top * (1 - ty) + bottom * ty
    }

    public func sample(direction d: Vec3) -> SIMD4<Float> {
        sample(pixel: Equirect.pixel(from: d, width: layer.width, height: layer.height))
    }
}

extension TiledLayer {
    // MARK: - Remplissage (ColorDrop)

    /// Remplit la zone connexe autour de `seed` dont les pixels ressemblent à celui de départ (écart encodé ≤ `threshold`, alpha compris).
    /// Voisinage : 4 voisins, longitude bouclée, et à travers les pôles (première et dernière rangées).
    /// Renvoie les tuiles modifiées (enregistrées dans l'opération en cours s'il y en a une).
    @discardableResult
    public func floodFill(from seed: Vec3, color: SIMD4<Float>, threshold: Float, space: BlendSpace) -> Set<TileCoord> {
        let filled = floodMask(from: seed, threshold: threshold)
        let dab = SphericalDab(center: [0, 0, -1], radius: 1, hardness: 1, color: color)
        return applyMask(filled) { pixel in SphericalRasterizer.apply(dab, coverage: 1, to: &pixel, space: space) }
    }

    /// Zone connexe autour de `seed` (un booléen par pixel, ligne par ligne) : sert au remplissage et à la sélection automatique.
    public func floodMask(from seed: Vec3, threshold: Float) -> [Bool] {
        let w = width, h = height
        let sampler = LayerSampler(self)
        let start = Equirect.pixel(from: seed, width: w, height: h)
        let sx = min(w - 1, max(0, Int(start.x)))
        let sy = min(h - 1, max(0, Int(start.y)))
        func key(_ p: SIMD4<Float>) -> SIMD4<Float> {
            guard p.w > 0 else { return .zero }
            let e = ColorTransfer.toEncoded(SIMD3<Float>(p.x, p.y, p.z) / p.w)
            return SIMD4<Float>(e.x, e.y, e.z, p.w)
        }
        let reference = key(sampler.texel(sx, sy))
        func matches(_ x: Int, _ y: Int) -> Bool {
            let d = key(sampler.texel(x, y)) - reference
            return max(max(abs(d.x), abs(d.y)), max(abs(d.z), abs(d.w))) <= threshold
        }

        var filled = [Bool](repeating: false, count: w * h)
        var stack = [(sx, sy)]
        // Remplissage par segments horizontaux (scanline), avec bouclage sur la couture.
        while let (x, y) = stack.popLast() {
            if filled[y * w + x] || !matches(x, y) { continue }
            var left = x
            var count = 1
            while count < w {
                let next = (left - 1 + w) % w
                if filled[y * w + next] || !matches(next, y) { break }
                left = next
                count += 1
            }
            var right = x
            while count < w {
                let next = (right + 1) % w
                if filled[y * w + next] || !matches(next, y) { break }
                right = next
                count += 1
            }
            var cx = left
            for _ in 0..<count {
                filled[y * w + cx] = true
                for ny in [y - 1, y + 1] {
                    if ny >= 0 && ny < h {
                        if !filled[ny * w + cx] { stack.append((cx, ny)) }
                    } else {
                        // À travers le pôle : même rangée, longitude opposée.
                        let opposite = (cx + w / 2) % w
                        if !filled[y * w + opposite] { stack.append((opposite, y)) }
                    }
                }
                cx = (cx + 1) % w
            }
        }
        return filled
    }

    // MARK: - Dégradé

    /// Peint un dégradé de `from` vers `to` (couleurs droites linéaires, alpha = opacité) sur tout le calque.
    @discardableResult
    public func applyGradient(_ gradient: SphericalGradient, from: SIMD4<Float>, to: SIMD4<Float>,
                              space: BlendSpace) -> Set<TileCoord> {
        var touched = Set<TileCoord>()
        let side = TileSize.side
        let geometry = geometry
        let width = width, height = height
        // Une rangée de tuiles à la fois : calcul en parallèle (lecture seule du calque), écriture séquentielle.
        for ty in 0..<tilesDown {
            let coords = (0..<tilesAcross).map { TileCoord(x: $0, y: ty) }
            let sources = coords.map { tileFloatPixels($0) }
            var results = [[SIMD4<Float>]](repeating: [], count: coords.count)
            results.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: coords.count) { i in
                    var pixels = sources[i]
                    let coord = coords[i]
                    for y in 0..<side {
                        for x in 0..<side {
                            let gx = coord.x * side + x, gy = coord.y * side + y
                            guard gx < width, gy < height else { continue }
                            let t = Float(gradient.parameter(at: geometry.direction(x: gx, y: gy)))
                            let dab = SphericalDab(center: [0, 0, -1], radius: 1, hardness: 1, color: from + (to - from) * t)
                            SphericalRasterizer.apply(dab, coverage: 1, to: &pixels[y * side + x], space: space)
                        }
                    }
                    out[i] = pixels
                }
            }
            for (i, coord) in coords.enumerated() {
                replaceTile(coord, withPixels: results[i])
                touched.insert(coord)
            }
        }
        return touched
    }

    // MARK: - Doigt et clonage

    /// Doigt : chaque texel du dab reçoit la couleur transportée depuis le dab précédent (rotation `previous` → `dab.center`),
    /// mélangée selon `strength` × couverture. Lit l'état courant du calque : la couleur s'étale le long du trait.
    @discardableResult
    public func smudge(_ dab: SphericalDab, from previous: Vec3, strength: Float) -> Set<TileCoord> {
        let back = Sphere.rotation(from: dab.center, to: previous)
        let sampler = LayerSampler(self)
        return transfer(dab) { d in sampler.sample(direction: back * d) } blend: { dst, src, a in
            dst + (src - dst) * (a * strength)
        }
    }

    /// Clonage : chaque texel du dab reçoit la couleur de `source` lue à travers `rotation` (direction peinte → direction source).
    @discardableResult
    public func clone(_ dab: SphericalDab, from source: LayerSampler, rotation: simd_double3x3) -> Set<TileCoord> {
        transfer(dab) { d in source.sample(direction: rotation * d) } blend: { dst, src, a in
            let sa = a * dab.color.w
            return src * sa + dst * (1 - sa)
        }
    }

    /// Calcule d'abord toutes les nouvelles valeurs (lecture), puis écrit : un dab ne lit jamais ce qu'il vient d'écrire.
    private func transfer(_ dab: SphericalDab, source: (Vec3) -> SIMD4<Float>,
                          blend: (SIMD4<Float>, SIMD4<Float>, Float) -> SIMD4<Float>) -> Set<TileCoord> {
        let evaluator = DabEvaluator(dab, pixelAngle: geometry.pixelAngle)
        let span = evaluator.span(in: geometry)
        var updates: [TileCoord: [(index: Int, value: SIMD4<Float>)]] = [:]
        let reader = LayerSampler(self)
        for y in span.rows {
            for columns in span.columns {
                for x in columns {
                    let d = geometry.direction(x: x, y: y)
                    let a = evaluator.coverage(at: d)
                    guard a > 0 else { continue }
                    let dst = reader.texel(x, y)
                    let value = blend(dst, source(d), a)
                    let coord = TileCoord.containing(x: x, y: y)
                    updates[coord, default: []].append(((y % TileSize.side) * TileSize.side + x % TileSize.side, value))
                }
            }
        }
        for (coord, changes) in updates {
            var pixels = tileFloatPixels(coord)
            for change in changes { pixels[change.index] = change.value }
            replaceTile(coord, withPixels: pixels)
        }
        return Set(updates.keys)
    }

    // MARK: - Rotation (référence CPU)

    /// Tourne tout le contenu : le texel de direction d prend la valeur de la source en Rᵀ·d (bilinéaire).
    /// Référence pour le kernel GPU ; lent sur une grande toile.
    @discardableResult
    public func rotateContent(_ rotation: simd_double3x3) -> Set<TileCoord> {
        let source = LayerSampler(duplicate())
        let inverse = rotation.transpose
        var touched = Set<TileCoord>()
        let side = TileSize.side
        for ty in 0..<tilesDown {
            for tx in 0..<tilesAcross {
                let coord = TileCoord(x: tx, y: ty)
                var pixels = [SIMD4<Float>](repeating: .zero, count: TileSize.pixelCount)
                for y in 0..<side {
                    for x in 0..<side {
                        let gx = tx * side + x, gy = ty * side + y
                        guard gx < width, gy < height else { continue }
                        pixels[y * side + x] = source.sample(direction: inverse * geometry.direction(x: gx, y: gy))
                    }
                }
                if isStored(coord) || pixels.contains(where: { $0.w > 0 || $0.x != 0 }) {
                    replaceTile(coord, withPixels: pixels)
                    touched.insert(coord)
                }
            }
        }
        return touched
    }

    /// Applique `edit` aux pixels marqués dans un masque plein-calque (une valeur par pixel).
    private func applyMask(_ mask: [Bool], _ edit: (inout SIMD4<Float>) -> Void) -> Set<TileCoord> {
        var touched = Set<TileCoord>()
        let side = TileSize.side
        for ty in 0..<tilesDown {
            for tx in 0..<tilesAcross {
                var any = false
                outer: for y in (ty * side)..<min(height, ty * side + side) {
                    for x in (tx * side)..<min(width, tx * side + side) where mask[y * width + x] {
                        any = true
                        break outer
                    }
                }
                guard any else { continue }
                let coord = TileCoord(x: tx, y: ty)
                var pixels = tileFloatPixels(coord)
                for y in 0..<side {
                    for x in 0..<side {
                        let gx = tx * side + x, gy = ty * side + y
                        if gx < width, gy < height, mask[gy * width + gx] { edit(&pixels[y * side + x]) }
                    }
                }
                replaceTile(coord, withPixels: pixels)
                touched.insert(coord)
            }
        }
        return touched
    }
}
