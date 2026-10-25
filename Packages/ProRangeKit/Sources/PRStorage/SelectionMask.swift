import Foundation
import PRCore
import simd

/// Sélection : une valeur dans [0, 1] par pixel, stockée dans un calque tuilé (v, v, v, v).
/// Absente = rien de sélectionné ; tuile uniforme = entièrement sélectionnée : une sélection ne coûte presque rien.
/// Ses modifications passent par le calque (`layer`) : elles s'enregistrent dans l'historique comme n'importe quel calque.
public final class SelectionMask {
    public let layer: TiledLayer
    private var cache: [TileCoord: [Float]] = [:]

    public init(width: Int, height: Int) {
        layer = TiledLayer(name: "Sélection", width: width, height: height, format: .rgba16Float)
    }

    public var isEmpty: Bool { layer.storedTiles.isEmpty }
    public var width: Int { layer.width }
    public var height: Int { layer.height }

    /// Valeurs d'une tuile (nil si rien n'y est sélectionné).
    public func tileValues(_ coord: TileCoord) -> [Float]? {
        guard layer.isStored(coord) else { return nil }
        if let cached = cache[coord] { return cached }
        let values = layer.tileFloatPixels(coord).map(\.w)
        cache[coord] = values
        return values
    }

    /// À appeler après toute modification du calque hors de cette classe (annuler, rétablir).
    public func invalidateCache() {
        cache.removeAll()
    }

    public func value(x: Int, y: Int) -> Float {
        tileValues(TileCoord.containing(x: x, y: y))?[(y % TileSize.side) * TileSize.side + x % TileSize.side] ?? 0
    }

    // MARK: - Construction

    /// Combine une forme tracée dans une vue avec la sélection existante.
    public func apply(_ shape: SelectionShape, in projection: ProjectionParameters, mode: SelectionCombine) {
        let geometry = layer.geometry
        combine(mode) { coord in
            var values = [Float](repeating: 0, count: TileSize.pixelCount)
            var any = false
            for y in 0..<TileSize.side {
                for x in 0..<TileSize.side {
                    let d = geometry.direction(x: coord.x * TileSize.side + x, y: coord.y * TileSize.side + y)
                    if let p = projection.ndc(of: d), shape.contains(p) {
                        values[y * TileSize.side + x] = 1
                        any = true
                    }
                }
            }
            return any ? values : nil
        }
    }

    /// Combine une zone de pixels (sélection automatique) avec la sélection existante.
    public func apply(_ mask: [Bool], mode: SelectionCombine) {
        let w = width
        combine(mode) { coord in
            var values = [Float](repeating: 0, count: TileSize.pixelCount)
            var any = false
            for y in 0..<TileSize.side {
                let row = (coord.y * TileSize.side + y) * w + coord.x * TileSize.side
                for x in 0..<TileSize.side where mask[row + x] {
                    values[y * TileSize.side + x] = 1
                    any = true
                }
            }
            return any ? values : nil
        }
    }

    public func selectAll() {
        for coord in allTiles { layer.replaceTile(coord, withPixels: [SIMD4<Float>](repeating: .one, count: TileSize.pixelCount)) }
        cache.removeAll()
    }

    public func clear() {
        for coord in layer.storedTiles { layer.replaceTile(coord, withPixels: [SIMD4<Float>](repeating: .zero, count: TileSize.pixelCount)) }
        cache.removeAll()
    }

    public func invert() {
        for coord in allTiles {
            let values = tileValues(coord) ?? [Float](repeating: 0, count: TileSize.pixelCount)
            write(coord, values.map { 1 - $0 })
        }
        cache.removeAll()
    }

    /// Adoucit les bords : flou d'environ `radius` (radians) sur la sphère.
    /// Trois passes de flou boîte séparables ; le rayon horizontal grandit en 1/cos(latitude) pour rester constant en angle.
    public func feather(radius: Double) {
        let w = width, h = height
        let r = max(1, Int((radius / 3 / layer.geometry.pixelAngle).rounded()))
        var values = [Float](repeating: 0, count: w * h)
        for coord in layer.storedTiles {
            guard let tile = tileValues(coord) else { continue }
            for y in 0..<TileSize.side {
                let gy = coord.y * TileSize.side + y
                guard gy < h else { continue }
                for x in 0..<TileSize.side {
                    let gx = coord.x * TileSize.side + x
                    if gx < w { values[gy * w + gx] = tile[y * TileSize.side + x] }
                }
            }
        }
        var temp = [Float](repeating: 0, count: w * h)
        for _ in 0..<3 {
            // Horizontal, bouclé sur la couture, rayon dépendant de la latitude.
            for y in 0..<h {
                let lat = (0.5 - (Double(y) + 0.5) / Double(h)) * .pi
                let rx = min(w / 2 - 1, Int((Double(r) / max(cos(lat), 1e-3)).rounded()))
                var sum: Float = 0
                for k in -rx...rx { sum += values[y * w + ((k % w) + w) % w] }
                let norm = 1 / Float(2 * rx + 1)
                for x in 0..<w {
                    temp[y * w + x] = sum * norm
                    sum += values[y * w + (x + rx + 1) % w] - values[y * w + ((x - rx) % w + w) % w]
                }
            }
            // Vertical, borné aux pôles (on répète la rangée du bord).
            for x in 0..<w {
                var sum: Float = 0
                for k in -r...r { sum += temp[min(h - 1, max(0, k)) * w + x] }
                let norm = 1 / Float(2 * r + 1)
                for y in 0..<h {
                    values[y * w + x] = sum * norm
                    sum += temp[min(h - 1, y + r + 1) * w + x] - temp[max(0, y - r) * w + x]
                }
            }
        }
        for coord in allTiles {
            var tile = [Float](repeating: 0, count: TileSize.pixelCount)
            for y in 0..<TileSize.side {
                let gy = coord.y * TileSize.side + y
                guard gy < h else { continue }
                for x in 0..<TileSize.side {
                    let gx = coord.x * TileSize.side + x
                    if gx < w { tile[y * TileSize.side + x] = values[gy * w + gx] }
                }
            }
            write(coord, tile)
        }
        cache.removeAll()
    }

    /// Applique une transformation à la sélection elle-même (elle suit le contenu déplacé).
    public func transform(_ t: SphericalTransform) {
        warp { t.inverse($0) }
    }

    public func distort(_ d: SphericalDistort) {
        warp { d.inverse($0) }
    }

    /// Déformation de la sélection par mapping inverse (nil = rien de sélectionné à cet endroit).
    public func warp(_ inverse: (Vec3) -> Vec3?) {
        let snapshot = LayerSampler(layer.duplicate())
        let geometry = layer.geometry
        for coord in allTiles {
            var values = [Float](repeating: 0, count: TileSize.pixelCount)
            var any = false
            for y in 0..<TileSize.side {
                for x in 0..<TileSize.side {
                    let d = geometry.direction(x: coord.x * TileSize.side + x, y: coord.y * TileSize.side + y)
                    let v = inverse(d).map { snapshot.sample(direction: $0).w } ?? 0
                    values[y * TileSize.side + x] = v
                    if v > 0 { any = true }
                }
            }
            if any || layer.isStored(coord) { write(coord, values) }
        }
        cache.removeAll()
    }

    /// Direction moyenne des pixels sélectionnés (pondérée par la sélection) : point d'origine d'une transformation.
    public func centroid() -> Vec3? {
        var sum = Vec3.zero
        let geometry = layer.geometry
        for coord in layer.storedTiles {
            guard let values = tileValues(coord) else { continue }
            for y in stride(from: 0, to: TileSize.side, by: 4) {
                for x in stride(from: 0, to: TileSize.side, by: 4) {
                    let v = Double(values[y * TileSize.side + x])
                    if v > 0 {
                        sum += geometry.direction(x: coord.x * TileSize.side + x, y: coord.y * TileSize.side + y) * v
                    }
                }
            }
        }
        return simd_length(sum) > 1e-9 ? simd_normalize(sum) : nil
    }

    /// Plus grande distance angulaire entre `center` et un pixel sélectionné (échantillonnée) : taille d'une poignée de distorsion.
    public func angularRadius(around center: Vec3) -> Double? {
        var radius = 0.0
        let geometry = layer.geometry
        for coord in layer.storedTiles {
            guard let values = tileValues(coord) else { continue }
            for y in stride(from: 0, to: TileSize.side, by: 8) {
                for x in stride(from: 0, to: TileSize.side, by: 8) where values[y * TileSize.side + x] > 0.5 {
                    let d = geometry.direction(x: coord.x * TileSize.side + x, y: coord.y * TileSize.side + y)
                    radius = max(radius, Sphere.angle(center, d))
                }
            }
        }
        return radius > 0 ? radius : nil
    }

    // MARK: - Interne

    private var allTiles: [TileCoord] {
        (0..<layer.tilesDown).flatMap { ty in (0..<layer.tilesAcross).map { TileCoord(x: $0, y: ty) } }
    }

    private func write(_ coord: TileCoord, _ values: [Float]) {
        if values.allSatisfy({ $0 <= 0 }) {
            if layer.isStored(coord) { layer.replaceTile(coord, withPixels: [SIMD4<Float>](repeating: .zero, count: TileSize.pixelCount)) }
            return
        }
        layer.replaceTile(coord, withPixels: values.map { SIMD4<Float>(repeating: min(1, max(0, $0))) })
    }

    /// Calcule la nouvelle forme tuile par tuile (en parallèle), puis combine et écrit.
    private func combine(_ mode: SelectionCombine, shape: @escaping (TileCoord) -> [Float]?) {
        let coords = allTiles
        var shapes = [[Float]?](repeating: nil, count: coords.count)
        shapes.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: coords.count) { i in out[i] = shape(coords[i]) }
        }
        for (i, coord) in coords.enumerated() {
            let existing = tileValues(coord)
            if shapes[i] == nil && existing == nil { continue }
            if mode != .replace && shapes[i] == nil { continue }
            let new = shapes[i] ?? [Float](repeating: 0, count: TileSize.pixelCount)
            let old = existing ?? [Float](repeating: 0, count: TileSize.pixelCount)
            write(coord, zip(old, new).map { mode.combine($0, $1) })
        }
        cache.removeAll()
    }
}

extension TiledLayer {
    /// Copie limitée à la sélection (tout le calque sans sélection) : le contenu flottant d'une transformation.
    public func masked(by selection: SelectionMask?) -> TiledLayer {
        let copy = duplicate()
        guard let selection else { return copy }
        for coord in copy.storedTiles {
            guard let values = selection.tileValues(coord) else {
                copy.restore(.absent, at: coord)
                continue
            }
            var pixels = copy.tileFloatPixels(coord)
            for i in pixels.indices { pixels[i] *= values[i] }
            copy.replaceTile(coord, withPixels: pixels)
        }
        return copy
    }

    /// Limite l'opération en cours à la sélection : sur les tuiles données, chaque pixel revient vers son état d'avant
    /// l'opération en proportion de ce qui n'est pas sélectionné.
    public func constrainCurrentOperation(to selection: SelectionMask, tiles: Set<TileCoord>) {
        for coord in tiles {
            guard let before = beforeState(of: coord) else { continue }
            let values = selection.tileValues(coord)
            let after = tileFloatPixels(coord)
            let original = decode(before)
            var mixed = after
            for i in mixed.indices {
                let s = values?[i] ?? 0
                mixed[i] = original[i] + (after[i] - original[i]) * s
            }
            replaceTile(coord, withPixels: mixed)
        }
    }

    /// Déplace / tourne / met à l'échelle le contenu sélectionné (tout le calque sans sélection), par mapping inverse.
    /// Le contenu déplacé est posé par-dessus ce qui reste. Renvoie les tuiles modifiées.
    @discardableResult
    public func applyTransform(_ transform: SphericalTransform, selection: SelectionMask?) -> Set<TileCoord> {
        applyWarp(selection: selection) { transform.inverse($0) }
    }

    /// Distorsion par quatre coins du contenu sélectionné (tout le calque sans sélection).
    @discardableResult
    public func applyDistort(_ distort: SphericalDistort, selection: SelectionMask?) -> Set<TileCoord> {
        applyWarp(selection: selection) { distort.inverse($0) }
    }

    /// Déformation générique par mapping inverse : `inverse` donne la direction source d'une direction de destination
    /// (nil = rien n'y arrive). Le contenu sélectionné est retiré, déformé et reposé par-dessus le reste.
    @discardableResult
    public func applyWarp(selection: SelectionMask?, inverse: @escaping (Vec3) -> Vec3?) -> Set<TileCoord> {
        let snapshot = duplicate()
        let selectionSnapshot = selection?.layer.duplicate()
        let geometry = geometry
        let width = width, height = height
        var touched = Set<TileCoord>()
        for ty in 0..<tilesDown {
            let coords = (0..<tilesAcross).map { TileCoord(x: $0, y: ty) }
            var results = [[SIMD4<Float>]?](repeating: nil, count: coords.count)
            results.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: coords.count) { i in
                    let coord = coords[i]
                    let source = LayerSampler(snapshot)
                    let mask = selectionSnapshot.map { LayerSampler($0) }
                    var pixels = [SIMD4<Float>](repeating: .zero, count: TileSize.pixelCount)
                    var changed = false
                    for y in 0..<TileSize.side {
                        for x in 0..<TileSize.side {
                            let gx = coord.x * TileSize.side + x, gy = coord.y * TileSize.side + y
                            guard gx < width, gy < height else { continue }
                            let here = source.texel(gx, gy)
                            let keep = 1 - (mask?.texel(gx, gy).w ?? 1)
                            var moved = SIMD4<Float>.zero
                            if let from = inverse(geometry.direction(x: gx, y: gy)) {
                                moved = source.sample(direction: from) * (mask?.sample(direction: from).w ?? 1)
                            }
                            let value = moved + here * keep * (1 - moved.w)
                            pixels[y * TileSize.side + x] = value
                            if value != here { changed = true }
                        }
                    }
                    out[i] = changed ? pixels : nil
                }
            }
            for (i, coord) in coords.enumerated() {
                guard let pixels = results[i] else { continue }
                replaceTile(coord, withPixels: pixels)
                touched.insert(coord)
            }
        }
        return touched
    }
}
