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
        var tip: SIMD4<Float>      // cos(rotation), sin(rotation), forme présente, grain présent
        var grain: SIMD4<Float>    // 1 / taille du grain, profondeur, miroir de la forme, rondeur
        var grain2: SIMD4<Float>   // décalage du grain mobile (x, y), cos et sin de sa rotation
        var region: SIMD4<Int32>   // x0, y0, largeur, hauteur (en texels)
    }

    public let device: any MTLDevice
    private let pipeline: any MTLComputePipelineState
    private let clampSampler: any MTLSamplerState
    private let repeatSampler: any MTLSamplerState
    /// Texture 1 × 1 blanche liée quand le dab n'a pas de forme ou de grain.
    private let blank: any MTLTexture
    private var tipTextures: [BrushTexture: any MTLTexture] = [:]

    public init(device: any MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.source, options: nil)
        guard let function = library.makeFunction(name: "stampDab") else { throw Failure.noFunction }
        pipeline = try device.makeComputePipelineState(function: function)
        func sampler(_ mode: MTLSamplerAddressMode) throws -> any MTLSamplerState {
            let desc = MTLSamplerDescriptor()
            desc.minFilter = .linear
            desc.magFilter = .linear
            desc.sAddressMode = mode
            desc.tAddressMode = mode
            guard let state = device.makeSamplerState(descriptor: desc) else { throw Failure.noFunction }
            return state
        }
        clampSampler = try sampler(.clampToEdge)
        repeatSampler = try sampler(.repeat)
        blank = try Self.makeTexture(device: device, BrushTexture(name: "blanc", size: 1, values: [1]))
    }

    private static func makeTexture(device: any MTLDevice, _ texture: BrushTexture) throws -> any MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: texture.size, height: texture.size, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let gpu = device.makeTexture(descriptor: desc) else { throw Failure.noFunction }
        texture.values.withUnsafeBytes { raw in
            gpu.replace(region: MTLRegionMake2D(0, 0, texture.size, texture.size), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: texture.size * 4)
        }
        return gpu
    }

    /// Texture GPU d'une forme ou d'un grain (créée une fois, gardée tant que le moteur vit ; au plus 16).
    private func gpuTexture(_ texture: BrushTexture?) -> any MTLTexture {
        guard let texture else { return blank }
        if let cached = tipTextures[texture] { return cached }
        if tipTextures.count >= 16 { tipTextures.removeAll() }
        let gpu = (try? Self.makeTexture(device: device, texture)) ?? blank
        tipTextures[texture] = gpu
        return gpu
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
        encoder.setSamplerState(clampSampler, index: 0)
        encoder.setSamplerState(repeatSampler, index: 1)
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
            let tip = dab.tip
            let rotation = tip?.rotation ?? 0
            let grainMode: Float = tip?.grain == nil ? 0 : (tip?.grainMoving == true ? 2 : 1)
            let tipVector = SIMD4<Float>(Float(cos(rotation)), Float(sin(rotation)), tip?.shape != nil ? 1 : 0, grainMode)
            let grainVector = SIMD4<Float>(Float(1 / (tip?.grainScale ?? 1)), Float(tip?.grainDepth ?? 0),
                                           tip?.flipX == true ? 1 : 0, Float(max(0.05, tip?.roundness ?? 1)))
            let grainRotation = tip?.grainRotation ?? 0
            let offset = tip?.grainOffset ?? .zero
            let grain2Vector = SIMD4<Float>(Float(offset.x), Float(offset.y), Float(cos(grainRotation)), Float(sin(grainRotation)))
            encoder.setTexture(gpuTexture(tip?.shape), index: 1)
            encoder.setTexture(gpuTexture(tip?.grain), index: 2)
            for columns in span.columns {
                let region = SIMD4<Int32>(Int32(columns.lowerBound), Int32(span.rows.lowerBound),
                                          Int32(columns.count), Int32(span.rows.count))
                var gpu = GPUDab(center: center, params: params, color: dab.color,
                                 options: SIMD4<Float>(spaceFlag, lockFlag, 0, 0), tip: tipVector, grain: grainVector,
                                 grain2: grain2Vector, region: region)
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
        float4 tip;
        float4 grain;
        float4 grain2;
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
                         texture2d<float> shape [[texture(1)]],
                         texture2d<float> grain [[texture(2)]],
                         sampler clampSampler [[sampler(0)]],
                         sampler repeatSampler [[sampler(1)]],
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
        float3 tangent = d - c * cosA;
        float sinA = length(tangent);
        float distance = atan2(sinA, cosA);
        float a;
        // Coordonnées du plan tangent (azimutal équidistant) : pour la forme et pour le grain mobile.
        float px = 0.0, py = 0.0;
        if (dab.tip.z > 0.5 || dab.tip.w > 1.5) {
            float3 east = cross(c, float3(0.0, 1.0, 0.0));
            east = length(east) < 1e-6 ? float3(1.0, 0.0, 0.0) : normalize(east);
            float3 north = cross(east, c);
            float k = sinA > 1e-7 ? distance / sinA : 1.0;
            px = dot(tangent, east) * k;
            py = dot(tangent, north) * k;
        }
        if (dab.tip.z > 0.5) {
            // Forme : tournée, retournée, écrasée selon la rondeur, ramenée au carré [-1, 1]².
            float qx = (px * dab.tip.x + py * dab.tip.y) / dab.center.w;
            if (dab.grain.z > 0.5) { qx = -qx; }
            float qy = (-px * dab.tip.y + py * dab.tip.x) / dab.center.w / max(0.05, dab.grain.w);
            if (abs(qx) > 1.0 || abs(qy) > 1.0) { return; }
            a = shape.sample(clampSampler, float2((qx + 1.0) * 0.5, (1.0 - qy) * 0.5)).r;
        } else {
            a = coverage(distance, dab.center.w, dab.params.x, dab.params.y);
        }
        if (a <= 0.0) { return; }
        if (dab.tip.w > 1.5) {
            // Grain mobile : dans le repère du tampon, tourné et décalé.
            float gu = (px * dab.grain2.z + py * dab.grain2.w) * dab.grain.x + dab.grain2.x;
            float gv = (-px * dab.grain2.w + py * dab.grain2.z) * dab.grain.x + dab.grain2.y;
            float g = grain.sample(repeatSampler, float2(gu, gv)).r;
            a *= 1.0 - dab.grain.y * (1.0 - g);
        } else if (dab.tip.w > 0.5) {
            // Grain fixé à la sphère : trois projections planes mélangées (poids |d|^4).
            float3 w = abs(d);
            w = w * w;
            w = w * w;
            w /= (w.x + w.y + w.z);
            float s = dab.grain.x;
            float g = w.x * grain.sample(repeatSampler, d.yz * s).r
                    + w.y * grain.sample(repeatSampler, d.xz * s).r
                    + w.z * grain.sample(repeatSampler, d.xy * s).r;
            a *= 1.0 - dab.grain.y * (1.0 - g);
        }

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
