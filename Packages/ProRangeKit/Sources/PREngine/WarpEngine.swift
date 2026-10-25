import Metal
import PRCore
import PRStorage
import simd

/// Déformations globales sur GPU par mapping inverse : chaque texel de destination calcule sa direction d,
/// la ramène dans la source (ici Rᵀ·d pour une rotation) et y lit la valeur bilinéaire (longitude bouclée, latitude bornée).
/// Même calcul que `TiledLayer.rotateContent` (référence CPU).
public final class WarpEngine {
    public enum Failure: Error {
        case noFunction
        case allocationFailed
        case commandFailed
    }

    public let device: any MTLDevice
    private let pipeline: any MTLComputePipelineState
    private let sampler: any MTLSamplerState
    private let queue: any MTLCommandQueue

    public init(device: any MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.source, options: nil)
        guard let function = library.makeFunction(name: "rotateContent"),
              let queue = device.makeCommandQueue() else { throw Failure.noFunction }
        pipeline = try device.makeComputePipelineState(function: function)
        self.queue = queue
        let desc = MTLSamplerDescriptor()
        desc.minFilter = .linear
        desc.magFilter = .linear
        desc.sAddressMode = .repeat
        desc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: desc) else { throw Failure.noFunction }
        self.sampler = sampler
    }

    /// Tourne le contenu d'un calque et renvoie les deltas (l'opération est enregistrée sur le calque).
    public func rotate(_ layer: TiledLayer, by rotation: simd_double3x3) throws -> [TileDelta] {
        precondition(layer.format == .rgba16Float, "rotation GPU : calques 16 bits flottants")
        let side = TileSize.side
        func makeTexture(_ usage: MTLTextureUsage) throws -> any MTLTexture {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: layer.width,
                                                                height: layer.height, mipmapped: false)
            desc.usage = usage
            desc.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: desc) else { throw Failure.allocationFailed }
            return texture
        }
        let source = try makeTexture([.shaderRead])
        let destination = try makeTexture([.shaderWrite])
        let zeros = [UInt8](repeating: 0, count: TileSize.pixelCount * 8)
        for ty in 0..<layer.tilesDown {
            for tx in 0..<layer.tilesAcross {
                let coord = TileCoord(x: tx, y: ty)
                let bytes = layer.isStored(coord) ? layer.tileBytes(coord) : zeros
                bytes.withUnsafeBytes { raw in
                    source.replace(region: MTLRegionMake2D(tx * side, ty * side, side, side), mipmapLevel: 0,
                                   withBytes: raw.baseAddress!, bytesPerRow: side * 8)
                }
            }
        }

        let inverse = rotation.transpose
        var columns = [inverse.columns.0, inverse.columns.1, inverse.columns.2].map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.z), 0) }
        guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { throw Failure.commandFailed }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setSamplerState(sampler, index: 0)
        encoder.setBytes(&columns, length: MemoryLayout<SIMD4<Float>>.stride * 3, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreadgroups(MTLSize(width: (layer.width + 15) / 16, height: (layer.height + 15) / 16, depth: 1),
                                     threadsPerThreadgroup: group)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { throw Failure.commandFailed }

        layer.beginOperation()
        var bytes = [UInt8](repeating: 0, count: TileSize.pixelCount * 8)
        for ty in 0..<layer.tilesDown {
            for tx in 0..<layer.tilesAcross {
                bytes.withUnsafeMutableBytes { raw in
                    destination.getBytes(raw.baseAddress!, bytesPerRow: side * 8,
                                         from: MTLRegionMake2D(tx * side, ty * side, side, side), mipmapLevel: 0)
                }
                let coord = TileCoord(x: tx, y: ty)
                // Une tuile vide qui le reste n'est ni créée ni enregistrée.
                if layer.isStored(coord) || bytes.contains(where: { $0 != 0 }) { layer.replaceTile(coord, with: bytes) }
            }
        }
        return layer.endOperation()
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    constant float PI = 3.14159265358979;

    kernel void rotateContent(texture2d<float, access::sample> source [[texture(0)]],
                              texture2d<float, access::write> destination [[texture(1)]],
                              sampler s [[sampler(0)]],
                              constant float4* inverse [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        uint width = destination.get_width();
        uint height = destination.get_height();
        if (gid.x >= width || gid.y >= height) { return; }
        float theta = (float(gid.y) + 0.5) / float(height) * PI;
        float phi = ((float(gid.x) + 0.5) / float(width) - 0.5) * 2.0 * PI;
        float st = sin(theta);
        float3 d = float3(st * sin(phi), cos(theta), -st * cos(phi));
        float3 r = inverse[0].xyz * d.x + inverse[1].xyz * d.y + inverse[2].xyz * d.z;
        float2 uv = float2(atan2(r.x, -r.z) / (2.0 * PI) + 0.5, acos(clamp(r.y, -1.0, 1.0)) / PI);
        destination.write(source.sample(s, uv, level(0.0)), gid);
    }
    """
}
