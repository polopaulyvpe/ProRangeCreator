import Metal
import PRCore
import PRStorage

/// Texture équirectangulaire d'affichage (RGBA16F + mipmaps), construite depuis les tuiles d'un calque.
/// - Résolution plafonnée à `maxWidth` : au-delà, chaque tuile est réduite par moyenne de blocs (facteur puissance de 2).
/// - Seules les tuiles modifiées sont renvoyées au GPU ; les mipmaps sont régénérées une fois par image si besoin.
/// - Composite sur une couleur de fond opaque (le calque d'arrière-plan blanc du cahier des charges, en attendant la pile de calques).
public final class DisplayTexture {
    public enum Failure: Error {
        case allocationFailed
    }

    public let texture: any MTLTexture
    /// Pixels de calque par pixel d'affichage, sur chaque axe.
    public let factor: Int
    public let background: SIMD4<Float>
    private var mipmapsDirty = true
    private let tileSide: Int
    private lazy var backgroundTile: [Float16] = {
        var out = [Float16]()
        out.reserveCapacity(tileSide * tileSide * 4)
        for _ in 0..<(tileSide * tileSide) {
            out.append(Float16(background.x))
            out.append(Float16(background.y))
            out.append(Float16(background.z))
            out.append(Float16(background.w))
        }
        return out
    }()

    public init(device: any MTLDevice, layerWidth: Int, maxWidth: Int = 8192, background: SIMD4<Float> = [1, 1, 1, 1]) throws {
        var factor = 1
        while layerWidth / factor > maxWidth { factor *= 2 }
        precondition(factor <= TileSize.side, "réduction plus grande qu'une tuile")
        self.factor = factor
        self.background = background
        tileSide = TileSize.side / factor
        let width = layerWidth / factor
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: width / 2, mipmapped: true)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { throw Failure.allocationFailed }
        self.texture = texture
    }

    /// Octets occupés sur le GPU (mipmaps comprises).
    public var allocatedBytes: Int { texture.allocatedSize }

    /// Recopie tout le calque.
    public func uploadAll(_ layer: TiledLayer) {
        var coords: [TileCoord] = []
        for ty in 0..<layer.tilesDown {
            for tx in 0..<layer.tilesAcross { coords.append(TileCoord(x: tx, y: ty)) }
        }
        upload(layer, tiles: coords)
    }

    /// Recopie les tuiles données (composite sur le fond, réduites de `factor`).
    public func upload(_ layer: TiledLayer, tiles: some Sequence<TileCoord>) {
        for coord in tiles {
            let region = MTLRegionMake2D(coord.x * tileSide, coord.y * tileSide, tileSide, tileSide)
            guard region.origin.x + tileSide <= texture.width, region.origin.y + tileSide <= texture.height else { continue }
            let pixels = layer.isStored(coord) ? reduce(layer.tileFloatPixels(coord)) : backgroundTile
            pixels.withUnsafeBytes { raw in
                texture.replace(region: region, mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: tileSide * 8)
            }
            mipmapsDirty = true
        }
    }

    /// Régénère les mipmaps si des tuiles ont changé. À appeler avant de dessiner, dans le même tampon de commandes.
    public func finishUpdates(_ commands: any MTLCommandBuffer) {
        guard mipmapsDirty, texture.mipmapLevelCount > 1, let blit = commands.makeBlitCommandEncoder() else { return }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        mipmapsDirty = false
    }

    /// Moyenne par blocs `factor × factor` puis composite sur le fond.
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
                let c = p + background * (1 - p.w)
                let o = (y * tileSide + x) * 4
                out[o] = Float16(c.x)
                out[o + 1] = Float16(c.y)
                out[o + 2] = Float16(c.z)
                out[o + 3] = Float16(c.w)
            }
        }
        return out
    }
}
