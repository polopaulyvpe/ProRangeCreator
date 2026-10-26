import Foundation
import PRCore

extension TiledLayer {
    /// Copie à la moitié de la résolution : moyenne de blocs 2 × 2 (en prémultiplié, donc juste pour la transparence).
    /// Chaque tuile du résultat lit quatre tuiles source, en parallèle (lecture seule).
    public func halved() -> TiledLayer {
        let result = TiledLayer(id: id, name: name, width: width / 2, height: height / 2, format: format)
        result.opacity = opacity
        result.isVisible = isVisible
        let side = TileSize.side
        let half = side / 2
        let stored = Set(storedTiles)
        let targets = Array(Set(stored.map { TileCoord(x: $0.x / 2, y: $0.y / 2) }))
        var outputs = [[SIMD4<Float>]](repeating: [], count: targets.count)
        outputs.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: targets.count) { i in
                let target = targets[i]
                var pixels = [SIMD4<Float>](repeating: .zero, count: TileSize.pixelCount)
                for qy in 0..<2 {
                    for qx in 0..<2 {
                        let source = TileCoord(x: target.x * 2 + qx, y: target.y * 2 + qy)
                        guard stored.contains(source) else { continue }
                        let p = tileFloatPixels(source)
                        for y in 0..<half {
                            for x in 0..<half {
                                let s = (2 * y) * side + 2 * x
                                let sum = p[s] + p[s + 1] + p[s + side] + p[s + side + 1]
                                pixels[(qy * half + y) * side + qx * half + x] = sum * 0.25
                            }
                        }
                    }
                }
                out[i] = pixels
            }
        }
        for (target, pixels) in zip(targets, outputs) where pixels.contains(where: { $0 != .zero }) {
            result.replaceTile(target, withPixels: pixels)
        }
        return result
    }
}

extension LayerStack {
    /// Toute la pile à la moitié de la résolution (calques et masques), structure et propriétés conservées.
    public func halved() -> LayerStack {
        let halvedItems = self.items.map { item -> StackItem in
            var copy = item
            if let layer = item.layer { copy.kind = .layer(layer.halved()) }
            copy.mask = item.mask?.halved()
            return copy
        }
        return LayerStack(width: width / 2, height: height / 2, format: format, items: halvedItems)
    }
}
