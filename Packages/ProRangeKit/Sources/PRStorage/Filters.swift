import Foundation
import PRCore
import simd

extension TiledLayer {
    /// Applique un ajustement point par point (seules les tuiles peintes sont concernées). Renvoie les tuiles modifiées.
    @discardableResult
    public func applyAdjustment(_ adjustment: Adjustment) -> Set<TileCoord> {
        let coords = storedTiles
        var results = [[SIMD4<Float>]](repeating: [], count: coords.count)
        let sources = coords.map { tileFloatPixels($0) }
        results.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: coords.count) { i in
                out[i] = sources[i].map { adjustment.apply($0) }
            }
        }
        for (i, coord) in coords.enumerated() { replaceTile(coord, withPixels: results[i]) }
        return Set(coords)
    }

    /// Tout le calque dans un tableau (lignes de haut en bas) : pour les références de filtres sur de petites toiles.
    public func allPixels() -> [SIMD4<Float>] {
        var out = [SIMD4<Float>](repeating: .zero, count: width * height)
        for coord in storedTiles {
            let tile = tileFloatPixels(coord)
            for y in 0..<TileSize.side {
                let gy = coord.y * TileSize.side + y
                guard gy < height else { continue }
                for x in 0..<TileSize.side {
                    let gx = coord.x * TileSize.side + x
                    if gx < width { out[gy * width + gx] = tile[y * TileSize.side + x] }
                }
            }
        }
        return out
    }
}

/// Implémentations CPU de référence des filtres GPU (mêmes discrétisations), et un flou sphérique exact pour les valider.
public enum FilterReference {
    /// Nombre maximal d'échantillons de chaque côté d'un flou ; au-delà, on échantillonne avec un pas entier.
    public static let maxTaps = 64

    /// Rayon (en texels) et pas d'échantillonnage d'un flou gaussien d'écart-type `sigma` texels.
    public static func taps(sigma: Double) -> (radius: Int, step: Int) {
        let radius = max(1, Int((3 * sigma).rounded(.up)))
        return (radius, max(1, (radius + maxTaps - 1) / maxTaps))
    }

    /// Flou gaussien séparable sur l'équirectangulaire : vertical d'écart-type σ/pas angulaire, horizontal divisé par cos(latitude)
    /// (plafonné à la demi-largeur), longitude bouclée, latitude bornée. Même algorithme que le kernel GPU.
    public static func separableBlur(_ pixels: [SIMD4<Float>], width: Int, height: Int, sigma: Double) -> [SIMD4<Float>] {
        let pixelAngle = Double.pi / Double(height)
        let sigmaPixels = sigma / pixelAngle
        var horizontal = [SIMD4<Float>](repeating: .zero, count: pixels.count)
        for y in 0..<height {
            let lat = (0.5 - (Double(y) + 0.5) / Double(height)) * .pi
            let rowSigma = min(Double(width) / 6, sigmaPixels / max(cos(lat), 1e-4))
            let (radius, step) = taps(sigma: rowSigma)
            for x in 0..<width {
                var sum = SIMD4<Float>.zero
                var total: Float = 0
                for offset in stride(from: -(radius / step) * step, through: radius, by: step) {
                    let w = Float(exp(-0.5 * pow(Double(offset) / rowSigma, 2)))
                    sum += pixels[y * width + ((x + offset) % width + width) % width] * w
                    total += w
                }
                horizontal[y * width + x] = sum / total
            }
        }
        var out = [SIMD4<Float>](repeating: .zero, count: pixels.count)
        let (radius, step) = taps(sigma: sigmaPixels)
        for y in 0..<height {
            for x in 0..<width {
                var sum = SIMD4<Float>.zero
                var total: Float = 0
                for offset in stride(from: -(radius / step) * step, through: radius, by: step) {
                    let w = Float(exp(-0.5 * pow(Double(offset) / sigmaPixels, 2)))
                    sum += horizontal[min(height - 1, max(0, y + offset)) * width + x] * w
                    total += w
                }
                out[y * width + x] = sum / total
            }
        }
        return out
    }

    /// Flou gaussien exact sur la sphère (poids en angle, pondérés par l'angle solide des texels). Lent : petites images seulement.
    public static func exactSphericalBlur(_ pixels: [SIMD4<Float>], width: Int, height: Int, sigma: Double) -> [SIMD4<Float>] {
        let geometry = EquirectGeometry(width: width, height: height)
        let directions = (0..<(width * height)).map { geometry.direction(x: $0 % width, y: $0 / width) }
        let solid = (0..<height).map { geometry.texelSolidAngle(row: $0) }
        let cutoff = cos(min(Double.pi, 4 * sigma))
        return (0..<(width * height)).map { i in
            var sum = SIMD4<Double>.zero
            var total = 0.0
            for j in directions.indices {
                let c = simd_dot(directions[i], directions[j])
                guard c >= cutoff else { continue }
                let theta = acos(min(1, c))
                let w = exp(-0.5 * theta * theta / (sigma * sigma)) * solid[j / width]
                sum += SIMD4<Double>(pixels[j]) * w
                total += w
            }
            return SIMD4<Float>(sum / total)
        }
    }

    /// Grain sur la valeur encodée (même hachage que le kernel).
    public static func noise(_ pixels: [SIMD4<Float>], width: Int, height: Int, amount: Double, cell: Double,
                             seed: UInt32, monochrome: Bool) -> [SIMD4<Float>] {
        let geometry = EquirectGeometry(width: width, height: height)
        return pixels.indices.map { i in
            let p = pixels[i]
            guard p.w > 0 else { return p }
            let d = geometry.direction(x: i % width, y: i / width)
            let n = (0..<3).map { k in SphericalNoise.value(d, cell: cell, seed: seed, channel: monochrome ? 0 : UInt32(k)) }
            var e = ColorTransfer.toEncoded(SIMD3<Float>(p.x, p.y, p.z) / p.w)
            e += SIMD3<Float>(n[0] - 0.5, n[1] - 0.5, n[2] - 0.5) * Float(2 * amount)
            let l = ColorTransfer.toLinear(simd_max(e, .zero)) * p.w
            return SIMD4<Float>(l.x, l.y, l.z, p.w)
        }
    }

    /// Aberration chromatique : rouge lu plus loin du centre, bleu plus près (même calcul que le kernel).
    public static func chromaticAberration(_ layer: TiledLayer, center: Vec3, strength: Double) -> [SIMD4<Float>] {
        let sampler = LayerSampler(layer)
        let frame = TangentFrame(center: center)
        let geometry = layer.geometry
        return (0..<(layer.width * layer.height)).map { i in
            let d = geometry.direction(x: i % layer.width, y: i / layer.width)
            let p = frame.project(d)
            let red = sampler.sample(direction: frame.unproject(p / (1 + strength)))
            let green = sampler.sample(direction: d)
            let blue = sampler.sample(direction: frame.unproject(p / (1 - strength)))
            return SIMD4<Float>(red.x, green.y, blue.z, green.w)
        }
    }
}
