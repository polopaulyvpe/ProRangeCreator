import Foundation
import PRCore

/// Compositeur CPU de référence : compose la pile tuile par tuile (export, caches d'affichage, fusion, tests du GPU).
/// - Groupes composés à part (sur transparent), puis fondus comme un calque.
/// - Masque : multiplie l'alpha de l'élément par le canal rouge du masque.
/// - Écrêtage : l'élément est limité à l'alpha (masque compris, opacité non comprise) du dernier élément non écrêté dessous ;
///   si cet élément est masqué (invisible), les éléments écrêtés le sont aussi.
public enum LayerCompositor {
    /// Composite de toute la pile pour une tuile, sur le papier (ou transparent si `paper` est nil).
    public static func compositeTile(_ coord: TileCoord, stack: LayerStack, paper: SIMD3<Float>?,
                                     space: BlendSpace) -> [SIMD4<Float>] {
        compositeChildren(of: nil, in: stack, coord: coord, range: nil, base: base(paper), space: space)
    }

    /// Composite d'une partie des éléments racine (indices dans `stack.children(of: nil)`).
    public static func compositeTile(_ coord: TileCoord, stack: LayerStack, rootRange: Range<Int>,
                                     paper: SIMD3<Float>?, space: BlendSpace) -> [SIMD4<Float>] {
        compositeChildren(of: nil, in: stack, coord: coord, range: rootRange, base: base(paper), space: space)
    }

    static func base(_ paper: SIMD3<Float>?) -> [SIMD4<Float>] {
        let value = paper.map { SIMD4<Float>($0.x, $0.y, $0.z, 1) } ?? .zero
        return [SIMD4<Float>](repeating: value, count: TileSize.pixelCount)
    }

    static func compositeChildren(of parent: UUID?, in stack: LayerStack, coord: TileCoord, range: Range<Int>?,
                                  base: [SIMD4<Float>], space: BlendSpace) -> [SIMD4<Float>] {
        let all = stack.children(of: parent)
        let children = range.map { Array(all[$0.clamped(to: all.indices)]) } ?? all
        var acc = base
        var clipBase: [Float]? // alpha de la base d'écrêtage courante ; nil = aucune
        for item in children {
            if item.isClipped {
                guard item.isVisible, let clip = clipBase, var source = Self.source(of: item, in: stack, coord: coord, space: space) else { continue }
                for i in source.indices { source[i] *= clip[i] }
                blend(&acc, source, item, space)
                continue
            }
            let source = item.isVisible ? Self.source(of: item, in: stack, coord: coord, space: space) : nil
            clipBase = source.map { $0.map(\.w) } ?? (item.isVisible ? [Float](repeating: 0, count: TileSize.pixelCount) : nil)
            if let source { blend(&acc, source, item, space) }
        }
        return acc
    }

    /// Pixels de l'élément (masque compris), ou nil s'il est entièrement transparent sur cette tuile.
    static func source(of item: StackItem, in stack: LayerStack, coord: TileCoord, space: BlendSpace) -> [SIMD4<Float>]? {
        var pixels: [SIMD4<Float>]
        switch item.kind {
        case .layer(let layer):
            guard layer.isStored(coord) else { return nil }
            pixels = layer.tileFloatPixels(coord)
        case .group:
            pixels = compositeChildren(of: item.id, in: stack, coord: coord, range: nil,
                                       base: [SIMD4<Float>](repeating: .zero, count: TileSize.pixelCount), space: space)
        }
        if let mask = item.mask {
            guard mask.isStored(coord) else { return nil }
            let values = mask.tileFloatPixels(coord)
            for i in pixels.indices { pixels[i] *= min(1, max(0, values[i].x)) }
        }
        return pixels
    }

    /// Raccourcis exacts avant le calcul complet (9 conversions de couleur par pixel) :
    /// - rien dessous : le résultat est la source à l'opacité du calque, quel que soit le mode ;
    /// - Normal, opaque, opacité pleine : la source remplace ce qui est dessous.
    private static func blend(_ acc: inout [SIMD4<Float>], _ source: [SIMD4<Float>], _ item: StackItem, _ space: BlendSpace) {
        let mode = item.blendMode
        let opacity = item.opacity
        let replaces = mode == .normal && opacity >= 1
        for i in acc.indices {
            let s = source[i]
            guard s.w > 0 else { continue }
            if acc[i].w <= 0 {
                acc[i] = s * opacity
            } else if replaces && s.w >= 1 {
                acc[i] = s
            } else {
                acc[i] = Compositing.composite(acc[i], s, mode: mode, opacity: opacity, space: space)
            }
        }
    }

    /// Toutes les tuiles où au moins un calque ou un masque a quelque chose.
    public static func occupiedTiles(_ stack: LayerStack) -> Set<TileCoord> {
        Set(stack.allTiledLayers.flatMap(\.storedTiles))
    }
}

extension LayerStack {
    /// Fusionne un calque dans le calque frère juste dessous (mode, opacité, masque et écrêtage appliqués).
    /// Renvoie l'entrée d'historique (pixels du calque du dessous + structure).
    public func mergeDown(_ id: UUID, space: BlendSpace) -> HistoryEntry? {
        guard let upper = item(id), upper.layer != nil else { return nil }
        let siblings = children(of: upper.parent)
        guard let position = siblings.firstIndex(where: { $0.id == id }), position > 0,
              let lowerLayer = siblings[position - 1].layer else { return nil }
        let lower = siblings[position - 1]
        let before = items

        // Les deux seuls, isolés : la base est le calque du dessous tel quel, sans son masque ni son mode.
        var pair = lower
        pair.mask = nil
        pair.blendMode = .normal
        pair.opacity = 1
        pair.isVisible = true
        pair.isClipped = false
        pair.parent = nil
        var top = upper
        top.parent = nil
        top.isVisible = true
        let temporary = LayerStack(width: width, height: height, format: format, items: [pair, top])

        lowerLayer.beginOperation()
        let tiles = Set(lowerLayer.storedTiles + upper.layer!.storedTiles + (upper.mask?.storedTiles ?? []))
        for coord in tiles {
            let merged = LayerCompositor.compositeTile(coord, stack: temporary, paper: nil, space: space)
            lowerLayer.replaceTile(coord, withPixels: merged)
        }
        let deltas = lowerLayer.endOperation()
        remove(id)
        return HistoryEntry(name: "Fusionner vers le bas", layerID: lowerLayer.id, deltas: deltas, structure: (before, items))
    }

    /// Aplatit toute la pile visible en un seul calque (sans le papier).
    public func flatten(space: BlendSpace) -> HistoryEntry? {
        let before = items
        let flat = TiledLayer(name: "Calque aplati", width: width, height: height, format: format)
        flat.beginOperation()
        for coord in LayerCompositor.occupiedTiles(self) {
            flat.replaceTile(coord, withPixels: LayerCompositor.compositeTile(coord, stack: self, paper: nil, space: space))
        }
        let deltas = flat.endOperation()
        restoreStructure([StackItem(kind: .layer(flat), name: "Calque aplati")])
        return HistoryEntry(name: "Aplatir", layerID: flat.id, deltas: deltas, structure: (before, items))
    }
}
