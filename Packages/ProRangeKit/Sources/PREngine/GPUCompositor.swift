import Foundation
import Metal
import PRCore
import PRStorage

/// Composition des calques sur le GPU, pour les caches d'affichage (dessous et dessus du calque actif).
/// Même mélange que le shader d'affichage (`compositeLayer`, copie exacte de `Compositing.composite`), appliqué tuile par
/// tuile : seules les tuiles peintes de chaque calque sont envoyées puis fondues, en un seul calcul par calque.
/// Les piles avec groupes, masques ou écrêtage restent au compositeur CPU (`LayerCompositor`).
final class GPUCompositor {
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let blendPipeline: any MTLComputePipelineState
    private let fillPipeline: any MTLComputePipelineState
    /// Texture de passage (un calque à la fois), à la taille de la toile.
    private var scratch: (any MTLTexture)?

    struct BlendParams {
        var mode: Int32
        var opacity: Float
        var perceptual: Int32
        var tileSide: Int32
    }

    init?(device: any MTLDevice, queue: any MTLCommandQueue) {
        guard let library = try? device.makeLibrary(source: PanoramaShaders.source + Self.kernels, options: nil),
              let blend = library.makeFunction(name: "compositeTiles"), let fill = library.makeFunction(name: "fillTiles"),
              let blendPipeline = try? device.makeComputePipelineState(function: blend),
              let fillPipeline = try? device.makeComputePipelineState(function: fill) else { return nil }
        self.device = device
        self.queue = queue
        self.blendPipeline = blendPipeline
        self.fillPipeline = fillPipeline
    }

    /// Vrai si ces éléments se composent sur le GPU : calques simples (ni groupe, ni masque, ni écrêtage).
    static func supports(_ items: [StackItem]) -> Bool {
        items.allSatisfy { !$0.isGroup && $0.mask == nil && !$0.isClipped }
    }

    /// Compose `items` (de bas en haut) sur `base` dans les tuiles `tiles` de `target`.
    func composite(_ items: [StackItem], base: SIMD4<Float>, space: BlendSpace, tiles: [TileCoord], into target: any MTLTexture) {
        guard !tiles.isEmpty else { return }
        let side = TileSize.side
        guard let scratch = scratchTexture(width: target.width, height: target.height) else { return }
        let wanted = Set(tiles)
        // Fond : papier ou transparent, partout où l'on recompose.
        run { encoder in
            var value = base
            encoder.setComputePipelineState(fillPipeline)
            encoder.setTexture(target, index: 0)
            encoder.setBytes(&value, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            dispatch(encoder, tiles: tiles, side: side)
        }
        for item in items where item.isVisible && item.opacity > 0 {
            guard let layer = item.layer else { continue }
            let painted = layer.storedTiles.filter { wanted.contains($0) }
            guard !painted.isEmpty else { continue }
            upload(layer, tiles: painted, into: scratch)
            run { encoder in
                var params = BlendParams(mode: Int32(PRCore.BlendMode.allCases.firstIndex(of: item.blendMode) ?? 0),
                                         opacity: item.opacity, perceptual: space == .perceptual ? 1 : 0, tileSide: Int32(side))
                encoder.setComputePipelineState(blendPipeline)
                encoder.setTexture(target, index: 0)
                encoder.setTexture(scratch, index: 1)
                encoder.setBytes(&params, length: MemoryLayout<BlendParams>.stride, index: 0)
                dispatch(encoder, tiles: painted, side: side)
            }
        }
    }

    // MARK: - Détails

    /// Encode, envoie et attend : la texture de passage peut ensuite être réécrite pour le calque suivant.
    private func run(_ body: (any MTLComputeCommandEncoder) -> Void) {
        guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { return }
        body(encoder)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
    }

    private func dispatch(_ encoder: any MTLComputeCommandEncoder, tiles: [TileCoord], side: Int) {
        var origins = tiles.map { SIMD2<Int32>(Int32($0.x * side), Int32($0.y * side)) }
        guard let buffer = device.makeBuffer(bytes: &origins, length: MemoryLayout<SIMD2<Int32>>.stride * origins.count,
                                             options: .storageModeShared) else { return }
        encoder.setBuffer(buffer, offset: 0, index: 1)
        encoder.dispatchThreadgroups(MTLSize(width: side / 16, height: side / 16, depth: tiles.count),
                                     threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    }

    private func scratchTexture(width: Int, height: Int) -> (any MTLTexture)? {
        if let scratch, scratch.width == width, scratch.height == height { return scratch }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        scratch = device.makeTexture(descriptor: desc)
        return scratch
    }

    /// Tuiles du calque vers la texture de passage : décodage en parallèle (lecture seule), envoi par paquets.
    private func upload(_ layer: TiledLayer, tiles: [TileCoord], into texture: any MTLTexture) {
        let side = TileSize.side
        let direct = layer.format == .rgba16Float
        let chunk = 64
        var start = 0
        while start < tiles.count {
            let slice = Array(tiles[start..<min(tiles.count, start + chunk)])
            var decoded = [[UInt8]](repeating: [], count: slice.count)
            decoded.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: slice.count) { i in
                    if direct {
                        out[i] = layer.tileBytes(slice[i])
                    } else {
                        var halves = [Float16](repeating: 0, count: TileSize.pixelCount * 4)
                        for (k, p) in layer.tileFloatPixels(slice[i]).enumerated() {
                            halves[k * 4] = Float16(p.x)
                            halves[k * 4 + 1] = Float16(p.y)
                            halves[k * 4 + 2] = Float16(p.z)
                            halves[k * 4 + 3] = Float16(p.w)
                        }
                        out[i] = halves.withUnsafeBytes { Array($0) }
                    }
                }
            }
            for (i, coord) in slice.enumerated() {
                let x = coord.x * side, y = coord.y * side
                guard x + side <= texture.width, y + side <= texture.height else { continue }
                decoded[i].withUnsafeBytes { raw in
                    texture.replace(region: MTLRegionMake2D(x, y, side, side), mipmapLevel: 0,
                                    withBytes: raw.baseAddress!, bytesPerRow: side * 8)
                }
            }
            start += chunk
        }
    }

    static let kernels = """

    struct BlendParams {
        int mode;
        float opacity;
        int perceptual;
        int tileSide;
    };

    // Une tuile par plan z de la grille : origine lue dans la liste des tuiles à traiter.
    kernel void compositeTiles(texture2d<float, access::read_write> target [[texture(0)]],
                               texture2d<float, access::read> layer [[texture(1)]],
                               constant BlendParams& p [[buffer(0)]],
                               constant int2* origins [[buffer(1)]],
                               uint3 gid [[thread_position_in_grid]]) {
        uint2 pos = uint2(origins[gid.z]) + gid.xy;
        if (pos.x >= target.get_width() || pos.y >= target.get_height()) { return; }
        float4 s = layer.read(pos);
        if (s.w <= 0.0) { return; }
        float4 b = target.read(pos);
        target.write(compositeLayer(b, s, p.mode, p.opacity, p.perceptual != 0), pos);
    }

    kernel void fillTiles(texture2d<float, access::read_write> target [[texture(0)]],
                          constant float4& value [[buffer(0)]],
                          constant int2* origins [[buffer(1)]],
                          uint3 gid [[thread_position_in_grid]]) {
        uint2 pos = uint2(origins[gid.z]) + gid.xy;
        if (pos.x >= target.get_width() || pos.y >= target.get_height()) { return; }
        target.write(value, pos);
    }
    """
}
