import Metal
import PRCore
import PRStorage

/// Pinceau sphérique sur GPU : chaque dab est rendu texel par texel sur la texture équirectangulaire du calque.
/// Même calcul que `DabEvaluator` + `SphericalRasterizer.apply` (PRCore), en float, testé contre eux.
public final class BrushEngine {
    public enum Failure: Error {
        case noFunction
    }

    /// Paramètres d'un dab pour le kernel (même disposition qu'en MSL : six vecteurs de 16 octets).
    struct GPUDab {
        var center: SIMD4<Float>   // direction, rayon
        var params: SIMD4<Float>   // dureté, taille angulaire d'un texel, cos(portée), mode (0 peindre, 1 effacer)
        var color: SIMD4<Float>    // RGB linéaire non prémultiplié, opacité
        var options: SIMD4<Float>  // espace de fusion (0 perceptuel, 1 linéaire), verrou alpha, inutilisés
        var region: SIMD4<Int32>   // x0, y0, largeur, hauteur (en texels)
    }

    public let device: any MTLDevice
    private let pipeline: any MTLComputePipelineState

    public init(device: any MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.source, options: nil)
        guard let function = library.makeFunction(name: "stampDab") else { throw Failure.noFunction }
        pipeline = try device.makeComputePipelineState(function: function)
    }

    /// Encode les dabs, dans l'ordre, sur `texture` (RGBA16F lecture/écriture). Renvoie les tuiles touchées.
    @discardableResult
    public func encode(_ dabs: [SphericalDab], space: BlendSpace, alphaLock: Bool = false, into texture: any MTLTexture,
                       commandBuffer: any MTLCommandBuffer) -> Set<TileCoord> {
        guard !dabs.isEmpty, let encoder = commandBuffer.makeComputeCommandEncoder() else { return [] }
        let geometry = (width: texture.width, height: texture.height)
        let pixelAngle = Double.pi / Double(geometry.height)
        var touched = Set<TileCoord>()
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        for dab in dabs {
            let evaluator = DabEvaluator(dab, pixelAngle: pixelAngle)
            let span = EquirectSpan(center: evaluator.frame.center, radius: evaluator.reach,
                                    width: geometry.width, height: geometry.height)
            let c = evaluator.frame.center
            let center = SIMD4<Float>(Float(c.x), Float(c.y), Float(c.z), Float(dab.radius))
            let modeFlag: Float = dab.mode == .erase ? 1 : 0
            let params = SIMD4<Float>(Float(dab.hardness), Float(pixelAngle), Float(cos(evaluator.reach)), modeFlag)
            let spaceFlag: Float = space == .linear ? 1 : 0
            let lockFlag: Float = alphaLock ? 1 : 0
            for columns in span.columns {
                let region = SIMD4<Int32>(Int32(columns.lowerBound), Int32(span.rows.lowerBound),
                                          Int32(columns.count), Int32(span.rows.count))
                var gpu = GPUDab(center: center, params: params, color: dab.color,
                                 options: SIMD4<Float>(spaceFlag, lockFlag, 0, 0), region: region)
                encoder.setBytes(&gpu, length: MemoryLayout<GPUDab>.stride, index: 0)
                let groups = MTLSize(width: (columns.count + group.width - 1) / group.width,
                                     height: (span.rows.count + group.height - 1) / group.height, depth: 1)
                encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: group)
                touched.formUnion(Self.tiles(columns: columns, rows: span.rows))
            }
        }
        encoder.endEncoding()
        return touched
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    constant float PI = 3.14159265358979;
    constant float SLOPE_AT_ONE = 1.055 / 2.4;

    struct Dab {
        float4 center;
        float4 params;
        float4 color;
        float4 options;
        int4 region;
    };

    static float toEncoded(float l) {
        float a = abs(l);
        float c = a <= 0.0031308 ? a * 12.92 : (a <= 1.0 ? 1.055 * pow(a, 1.0 / 2.4) - 0.055 : 1.0 + (a - 1.0) * SLOPE_AT_ONE);
        return l < 0.0 ? -c : c;
    }

    static float toLinear(float c) {
        float a = abs(c);
        float l = a <= 0.04045 ? a / 12.92 : (a <= 1.0 ? pow((a + 0.055) / 1.055, 2.4) : 1.0 + (a - 1.0) / SLOPE_AT_ONE);
        return c < 0.0 ? -l : l;
    }

    static float3 toEncoded3(float3 v) { return float3(toEncoded(v.x), toEncoded(v.y), toEncoded(v.z)); }
    static float3 toLinear3(float3 v) { return float3(toLinear(v.x), toLinear(v.y), toLinear(v.z)); }

    static float coverage(float distance, float radius, float hardness, float pixelSize) {
        float rho = distance / radius;
        float e = pixelSize / radius;
        float edge = clamp((1.0 - rho) / e + 0.5, 0.0, 1.0);
        if (hardness >= 1.0 || rho <= hardness) { return edge; }
        float t = min(1.0, (rho - hardness) / (1.0 - hardness));
        return edge * (1.0 - t * t * (3.0 - 2.0 * t));
    }

    kernel void stampDab(texture2d<float, access::read_write> layer [[texture(0)]],
                         constant Dab& dab [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= uint(dab.region.z) || gid.y >= uint(dab.region.w)) { return; }
        int width = int(layer.get_width());
        int height = int(layer.get_height());
        int x = (dab.region.x + int(gid.x)) % width;
        int y = dab.region.y + int(gid.y);

        float theta = (float(y) + 0.5) / float(height) * PI;
        float phi = ((float(x) + 0.5) / float(width) - 0.5) * 2.0 * PI;
        float s = sin(theta);
        float3 d = float3(s * sin(phi), cos(theta), -s * cos(phi));

        float3 c = dab.center.xyz;
        float cosA = dot(c, d);
        if (cosA < dab.params.z) { return; }
        float sinA = length(d - c * cosA);
        float distance = atan2(sinA, cosA);
        float a = coverage(distance, dab.center.w, dab.params.x, dab.params.y);
        if (a <= 0.0) { return; }

        uint2 p = uint2(x, y);
        float4 dst = layer.read(p);
        float4 original = dst;
        float sa = a * dab.color.w;
        if (dab.params.w > 0.5) {
            dst *= 1.0 - sa;
        } else if (dab.options.x > 0.5) {
            dst = float4(dab.color.rgb * sa, sa) + dst * (1.0 - sa);
        } else {
            float da = dst.w;
            float outA = sa + da * (1.0 - sa);
            if (outA <= 0.0) {
                dst = float4(0.0);
            } else {
                float3 src = toEncoded3(dab.color.rgb);
                float3 below = da > 0.0 ? toEncoded3(dst.rgb / da) : float3(0.0);
                float3 mixed = (src * sa + below * (da * (1.0 - sa))) / outA;
                dst = float4(toLinear3(mixed) * outA, outA);
            }
        }
        if (dab.options.y > 0.5) {
            dst = (original.w > 0.0 && dst.w > 0.0) ? float4(dst.rgb / dst.w * original.w, original.w) : original;
        }
        layer.write(dst, p);
    }
    """
}

extension BrushEngine {
    static func tiles(columns: ClosedRange<Int>, rows: ClosedRange<Int>) -> [TileCoord] {
        let side = TileSize.side
        var out: [TileCoord] = []
        for ty in (rows.lowerBound / side)...(rows.upperBound / side) {
            for tx in (columns.lowerBound / side)...(columns.upperBound / side) { out.append(TileCoord(x: tx, y: ty)) }
        }
        return out
    }
}
