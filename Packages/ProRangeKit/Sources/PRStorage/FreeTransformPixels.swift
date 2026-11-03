import Foundation
import PRCore
import simd

// Pixels de la transformation libre : on découpe le contenu au début (il flotte au-dessus de la toile pendant le geste),
// puis on le recolle transformé à la fin. L'aperçu GPU fait le même calcul (PanoramaShaders).

extension LayerSampler {
    /// Valeur en coordonnées pixel continues avec le filtre demandé (bicubique : Catmull-Rom sur 4 × 4 texels).
    public func sample(pixel p: SIMD2<Double>, filter: ResamplingFilter) -> SIMD4<Float> {
        switch filter {
        case .bilinear:
            return sample(pixel: p)
        case .nearest:
            return texel(Int(floor(p.x)), Int(floor(p.y)))
        case .bicubic:
            let fx = p.x - 0.5, fy = p.y - 0.5
            let x0 = Int(floor(fx)), y0 = Int(floor(fy))
            let wx = Self.catmullRom(Float(fx - Double(x0))), wy = Self.catmullRom(Float(fy - Double(y0)))
            var sum = SIMD4<Float>.zero
            for j in 0..<4 {
                var row = SIMD4<Float>.zero
                for i in 0..<4 { row += texel(x0 - 1 + i, y0 - 1 + j) * wx[i] }
                sum += row * wy[j]
            }
            // Le noyau dépasse un peu : alpha borné, couleur prémultipliée jamais négative ni au-dessus de l'alpha × 65504.
            let a = min(1, max(0, sum.w))
            return SIMD4<Float>(max(0, sum.x), max(0, sum.y), max(0, sum.z), a)
        }
    }

    public func sample(direction d: Vec3, filter: ResamplingFilter) -> SIMD4<Float> {
        sample(pixel: Equirect.pixel(from: d, width: layer.width, height: layer.height), filter: filter)
    }

    static func catmullRom(_ t: Float) -> SIMD4<Float> {
        let t2 = t * t, t3 = t2 * t
        return [(-t3 + 2 * t2 - t) / 2, (3 * t3 - 5 * t2 + 2) / 2, (-3 * t3 + 4 * t2 + t) / 2, (t3 - t2) / 2]
    }
}

extension TiledLayer {
    /// Directions des pixels visibles (alpha > 1/255), un sur `step` dans chaque sens : la boîte d'un calque entier.
    public func contentDirections(step: Int = 8) -> [Vec3] {
        var out: [Vec3] = []
        let g = geometry
        for coord in storedTiles.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            let pixels = tileFloatPixels(coord)
            for y in stride(from: 0, to: TileSize.side, by: step) {
                for x in stride(from: 0, to: TileSize.side, by: step) where pixels[y * TileSize.side + x].w > 1 / 255 {
                    let gx = coord.x * TileSize.side + x, gy = coord.y * TileSize.side + y
                    if gx < width, gy < height { out.append(g.direction(x: gx, y: gy)) }
                }
            }
        }
        return out
    }

    /// Retire le contenu sélectionné (tout le calque sans sélection). Renvoie l'état d'avant des tuiles changées,
    /// pour reconstituer une seule entrée d'historique à la fin, ou tout remettre si on annule.
    public func cut(selection: SelectionMask?) -> [TileCoord: TileState] {
        var before: [TileCoord: TileState] = [:]
        for coord in storedTiles {
            guard let selection else {
                before[coord] = state(of: coord)
                restore(.absent, at: coord)
                continue
            }
            guard let values = selection.tileValues(coord) else { continue }
            before[coord] = state(of: coord)
            var pixels = tileFloatPixels(coord)
            for i in pixels.indices { pixels[i] *= 1 - values[i] }
            replaceTile(coord, withPixels: pixels)
        }
        return before
    }

    /// Pose `floating` transformé par-dessus le calque (mapping inverse, filtre `filter`). Seules les tuiles où la boîte
    /// arrive sont calculées. Renvoie les tuiles modifiées.
    @discardableResult
    public func paste(_ floating: TiledLayer, transform: FreeTransform, filter: ResamplingFilter) -> Set<TileCoord> {
        guard let resolved = transform.resolved() else { return [] }
        let tiles = destinationTiles(of: resolved)
        let geometry = geometry
        let width = width, height = height
        let snapshot = duplicate()
        var touched = Set<TileCoord>()
        let coords = tiles.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        var results = [[SIMD4<Float>]?](repeating: nil, count: coords.count)
        results.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: coords.count) { i in
                let coord = coords[i]
                let source = LayerSampler(floating)
                let below = LayerSampler(snapshot)
                var pixels = [SIMD4<Float>](repeating: .zero, count: TileSize.pixelCount)
                var changed = false
                for y in 0..<TileSize.side {
                    for x in 0..<TileSize.side {
                        let gx = coord.x * TileSize.side + x, gy = coord.y * TileSize.side + y
                        guard gx < width, gy < height else { continue }
                        let here = below.texel(gx, gy)
                        var value = here
                        if let from = resolved.inverse(geometry.direction(x: gx, y: gy)) {
                            let moved = source.sample(direction: from, filter: filter)
                            if moved.w > 0 || moved.x != 0 { value = moved + here * (1 - moved.w) }
                        }
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
        return touched
    }

    /// Deltas de toute la transformation, pour une seule entrée d'historique : l'état d'avant la découpe (`cut`),
    /// ou d'avant le collage pour les autres tuiles, et l'état actuel.
    public func transformDeltas(cut: [TileCoord: TileState], pasted: [TileDelta]) -> [TileDelta] {
        var before = cut
        for delta in pasted where before[delta.coord] == nil { before[delta.coord] = delta.before }
        return before
            .compactMap { coord, old -> TileDelta? in
                let now = state(of: coord)
                return old == now ? nil : TileDelta(coord: coord, before: old, after: now)
            }
            .sorted { ($0.coord.y, $0.coord.x) < ($1.coord.y, $1.coord.x) }
    }

    /// Tuiles où arrive la boîte transformée (légèrement agrandie) : une grille de points de la boîte est envoyée
    /// sur la toile, et chaque tuile touchée est retenue avec ses voisines.
    func destinationTiles(of resolved: FreeTransform.Resolved) -> Set<TileCoord> {
        let t = resolved.transform
        var tiles = Set<TileCoord>()
        let n = 96
        for j in 0...n {
            for i in 0...n {
                let w = SIMD2<Double>(Double(i) / Double(n), Double(j) / Double(n)) * 1.04 - 0.02
                guard let d = resolved.apply(t.fromPlane(t.source(w))) else { continue }
                let p = Equirect.pixel(from: d, width: width, height: height)
                let cx = min(tilesAcross - 1, max(0, Int(p.x) / TileSize.side))
                let cy = min(tilesDown - 1, max(0, Int(p.y) / TileSize.side))
                for dy in -1...1 {
                    let ty = cy + dy
                    guard ty >= 0, ty < tilesDown else { continue }
                    for dx in -1...1 { tiles.insert(TileCoord(x: (cx + dx + tilesAcross) % tilesAcross, y: ty)) }
                }
            }
        }
        // Une boîte qui touche un pôle couvre toute la rangée polaire.
        for ty in [0, tilesDown - 1] where tiles.contains(where: { $0.y == ty }) {
            for tx in 0..<tilesAcross { tiles.insert(TileCoord(x: tx, y: ty)) }
        }
        return tiles
    }
}

extension SelectionMask {
    /// Directions des pixels sélectionnés (> 0,5), un sur `step` dans chaque sens : la boîte de la sélection.
    public func selectedDirections(step: Int = 8) -> [Vec3] {
        var out: [Vec3] = []
        let g = layer.geometry
        for coord in layer.storedTiles.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            guard let values = tileValues(coord) else { continue }
            for y in stride(from: 0, to: TileSize.side, by: step) {
                for x in stride(from: 0, to: TileSize.side, by: step) where values[y * TileSize.side + x] > 0.5 {
                    let gx = coord.x * TileSize.side + x, gy = coord.y * TileSize.side + y
                    if gx < width, gy < height { out.append(g.direction(x: gx, y: gy)) }
                }
            }
        }
        return out
    }

    /// La sélection suit le contenu transformé.
    public func transform(_ t: FreeTransform) {
        guard let resolved = t.resolved() else { return }
        warp { resolved.inverse($0) }
    }
}
