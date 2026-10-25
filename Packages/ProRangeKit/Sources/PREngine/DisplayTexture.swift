import Metal
import PRCore
import PRStorage

/// Texture équirectangulaire GPU d'un calque (RGBA16F linéaire prémultiplié + mipmaps).
/// - À pleine résolution (`factor` 1), c'est aussi la cible du pinceau GPU, et ses tuiles peuvent être relues (`readTile`).
/// - Au-delà de `maxWidth`, chaque tuile est réduite par moyenne de blocs (affichage seul).
/// - Le fond (papier blanc) n'est pas mélangé ici : le shader d'affichage le compose.
public final class DisplayTexture {
    public enum Failure: Error {
        case allocationFailed
    }

    public let texture: any MTLTexture
    /// Pixels de calque par pixel d'affichage, sur chaque axe.
    public let factor: Int
    private var mipmapsDirty = true
    private let tileSide: Int

    public init(device: any MTLDevice, layerWidth: Int, maxWidth: Int = 8192) throws {
        var factor = 1
        while layerWidth / factor > maxWidth { factor *= 2 }
        precondition(factor <= TileSize.side, "réduction plus grande qu'une tuile")
        self.factor = factor
        tileSide = TileSize.side / factor
        let width = layerWidth / factor
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: width / 2, mipmapped: true)
        desc.usage = factor == 1 ? [.shaderRead, .shaderWrite] : [.shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { throw Failure.allocationFailed }
        self.texture = texture
    }

    /// Vrai si le pinceau GPU peut peindre directement dans cette texture.
    public var isFullResolution: Bool { factor == 1 }

    /// Octets occupés sur le GPU (mipmaps comprises).
    public var allocatedBytes: Int { texture.allocatedSize }

    /// À appeler quand le contenu du niveau 0 a changé sur le GPU (pinceau).
    public func markChanged() { mipmapsDirty = true }

    /// Recopie tout le calque.
    public func uploadAll(_ layer: TiledLayer) {
        var coords: [TileCoord] = []
        for ty in 0..<layer.tilesDown {
            for tx in 0..<layer.tilesAcross { coords.append(TileCoord(x: tx, y: ty)) }
        }
        upload(layer, tiles: coords)
    }

    /// Recopie les tuiles données depuis le calque CPU.
    public func upload(_ layer: TiledLayer, tiles: some Sequence<TileCoord>) {
        for coord in tiles {
            let region = MTLRegionMake2D(coord.x * tileSide, coord.y * tileSide, tileSide, tileSide)
            guard region.origin.x + tileSide <= texture.width, region.origin.y + tileSide <= texture.height else { continue }
            let pixels: [Float16]
            if !layer.isStored(coord) {
                pixels = [Float16](repeating: 0, count: tileSide * tileSide * 4)
            } else if factor == 1, layer.format == .rgba16Float {
                // Mêmes octets que le calque : copie directe, exacte.
                let bytes = layer.tileBytes(coord)
                pixels = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
            } else {
                pixels = reduce(layer.tileFloatPixels(coord))
            }
            pixels.withUnsafeBytes { raw in
                texture.replace(region: region, mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: tileSide * 8)
            }
            mipmapsDirty = true
        }
    }

    /// Relit une tuile du niveau 0 (pleine résolution seulement), en octets RGBA16F.
    /// Le GPU doit avoir fini d'écrire (attendre le tampon de commandes avant).
    public func readTile(_ coord: TileCoord) -> [UInt8] {
        precondition(factor == 1, "relecture possible seulement à pleine résolution")
        var bytes = [UInt8](repeating: 0, count: TileSize.pixelCount * 8)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: TileSize.side * 8,
                             from: MTLRegionMake2D(coord.x * TileSize.side, coord.y * TileSize.side, TileSize.side, TileSize.side),
                             mipmapLevel: 0)
        }
        return bytes
    }

    /// Régénère les mipmaps si le contenu a changé. À appeler avant de dessiner, dans le même tampon de commandes.
    public func finishUpdates(_ commands: any MTLCommandBuffer) {
        guard mipmapsDirty, texture.mipmapLevelCount > 1, let blit = commands.makeBlitCommandEncoder() else { return }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        mipmapsDirty = false
    }

    /// Moyenne par blocs `factor × factor`.
    private func reduce(_ pixels: [SIMD4<Float>]) -> [Float16] {
        let side = TileSize.side
        let weight = 1 / Float(factor * factor)
        var out = [Float16](repeating: 0, count: tileSide * tileSide * 4)
        for y in 0..<tileSide {
            for x in 0..<tileSide {
                var sum = SIMD4<Float>.zero
                for dy in 0..<factor {
                    let row = (y * factor + dy) * side + x * factor
                    for dx in 0..<factor { sum += pixels[row + dx] }
                }
                let p = sum * weight
                let o = (y * tileSide + x) * 4
                out[o] = Float16(p.x)
                out[o + 1] = Float16(p.y)
                out[o + 2] = Float16(p.z)
                out[o + 3] = Float16(p.w)
            }
        }
        return out
    }
}
