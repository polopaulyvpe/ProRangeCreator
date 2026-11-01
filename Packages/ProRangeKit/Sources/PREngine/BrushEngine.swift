import Metal
import PRCore
import PRStorage

/// Pinceau sphérique sur GPU : chaque dab est rendu texel par texel sur la texture équirectangulaire du calque.
/// Même calcul que `DabEvaluator` + `SphericalRasterizer.apply` (PRCore), en float, testé contre eux.
///
/// Deux façons de peindre :
/// - `encode` pose chaque dab directement sur le calque (accumulation simple) ;
/// - `encodeStroke` accumule les dabs dans le masque du trait (`stampMask`), puis recalcule les tuiles touchées depuis
///   leur état d'avant le trait (`applyStroke`) : glacis, flux et pinceau double. Référence CPU : `StrokeMask`.
public final class BrushEngine {
    public enum Failure: Error {
        case noFunction
    }

    /// Paramètres d'un dab pour le kernel (même disposition qu'en MSL : neuf vecteurs de 16 octets).
    struct GPUDab {
        var center: SIMD4<Float>   // direction, rayon
        var params: SIMD4<Float>   // dureté, taille angulaire d'un texel, cos(portée), mode (0 peindre, 1 effacer)
        var color: SIMD4<Float>    // RGB linéaire non prémultiplié, opacité
        var options: SIMD4<Float>  // espace de fusion (0 perceptuel, 1 linéaire), verrou alpha, secondaire, flux
        var tip: SIMD4<Float>      // cos(rotation), sin(rotation), forme présente, grain présent
        var grain: SIMD4<Float>    // 1 / taille du grain, profondeur, miroir de la forme, rondeur
        var grain2: SIMD4<Float>   // décalage du grain mobile (x, y), cos et sin de sa rotation
        var extra: SIMD4<Float>    // fusion du grain (index de `DualBlendMode`), largeur de la forme, niveaux de réduction de la forme et du grain
        var region: SIMD4<Int32>   // x0, y0, largeur, hauteur (en texels)
    }

    /// Paramètres de `applyStroke`.
    struct GPUStroke {
        var color: SIMD4<Float>    // RGB linéaire non prémultiplié, mode (0 peindre, 1 effacer)
        var options: SIMD4<Float>  // plafond du principal, plafond du secondaire, combinaison (−1 aucune), espace (1 linéaire)
        var lock: SIMD4<Float>     // verrou alpha, inutilisés
    }

    public let device: any MTLDevice
    private let pipeline: any MTLComputePipelineState
    private let maskPipeline: any MTLComputePipelineState
    private let applyPipeline: any MTLComputePipelineState
    private let clampSampler: any MTLSamplerState
    private let repeatSampler: any MTLSamplerState
    /// Texture 1 × 1 blanche liée quand le dab n'a pas de forme ou de grain.
    private let blank: any MTLTexture
    /// Tuile de zéros recopiée dans le masque au premier passage du trait.
    private let zeroTile: any MTLTexture
    private var tipTextures: [BrushTexture: any MTLTexture] = [:]

    public init(device: any MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.source, options: nil)
        func pipeline(_ name: String) throws -> any MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw Failure.noFunction }
            return try device.makeComputePipelineState(function: function)
        }
        self.pipeline = try pipeline("stampDab")
        maskPipeline = try pipeline("stampMask")
        applyPipeline = try pipeline("applyStroke")
        func sampler(_ mode: MTLSamplerAddressMode) throws -> any MTLSamplerState {
            let desc = MTLSamplerDescriptor()
            desc.minFilter = .linear
            desc.magFilter = .linear
            desc.mipFilter = .linear
            desc.sAddressMode = mode
            desc.tAddressMode = mode
            guard let state = device.makeSamplerState(descriptor: desc) else { throw Failure.noFunction }
            return state
        }
        clampSampler = try sampler(.clampToEdge)
        repeatSampler = try sampler(.repeat)
        blank = try Self.makeTexture(device: device, BrushTexture(name: "blanc", size: 1, values: [1]))
        let side = TileSize.side
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: side, height: side, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let zero = device.makeTexture(descriptor: desc) else { throw Failure.noFunction }
        let zeros = [Float16](repeating: 0, count: side * side * 4)
        zeros.withUnsafeBytes { zero.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: side * 8) }
        zeroTile = zero
    }

    /// Forme ou grain avec sa pyramide de réductions (`BrushTexture.levels`, calculée sur le CPU : mêmes données des deux
    /// côtés). Demi-flottants : format filtrable sur tous les GPU Apple (le filtrage des flottants 32 bits ne l'est pas partout).
    private static func makeTexture(device: any MTLDevice, _ texture: BrushTexture) throws -> any MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: texture.size, height: texture.size,
                                                            mipmapped: texture.levels.count > 1)
        desc.mipmapLevelCount = texture.levels.count
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let gpu = device.makeTexture(descriptor: desc) else { throw Failure.noFunction }
        for (level, values) in texture.levels.enumerated() {
            let n = texture.levelSizes[level]
            let half = values.map { Float16($0) }
            half.withUnsafeBytes { raw in
                gpu.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: level, withBytes: raw.baseAddress!, bytesPerRow: n * 2)
            }
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

    /// Texture du masque d'un trait ou de la copie d'avant le trait, à la taille du calque (RGBA16F, privée au GPU).
    public func makeStrokeTexture(width: Int, height: Int) -> (any MTLTexture)? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)
    }

    /// Un dab prêt pour le kernel : paramètres et zones (une par bloc de colonnes, deux à la couture).
    private struct Prepared {
        var gpu: GPUDab
        var regions: [SIMD4<Int32>]
        var tiles: [TileCoord]
        var shape: BrushTexture?
        var grain: BrushTexture?
    }

    private func prepare(_ input: SphericalDab, width: Int, height: Int, space: BlendSpace, alphaLock: Bool) -> Prepared {
        let pixelAngle = Double.pi / Double(height)
        let evaluator = DabEvaluator(input, pixelAngle: pixelAngle)
        // Le dab tel que rendu (agrandi s'il est plus petit qu'un texel), comme sur le CPU.
        let dab = evaluator.dab
        let span = EquirectSpan(center: evaluator.frame.center, radius: evaluator.reach, width: width, height: height)
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
        let gpu = GPUDab(center: center, params: params, color: dab.color,
                         options: SIMD4<Float>(spaceFlag, lockFlag, dab.secondary ? 1 : 0, dab.flow), tip: tipVector,
                         grain: grainVector, grain2: grain2Vector,
                         extra: SIMD4<Float>(Float(tip?.grainBlend.index ?? 0), Float(max(0.05, tip?.width ?? 1)),
                                             evaluator.shapeLOD, evaluator.grainLOD),
                         region: .zero)
        var regions: [SIMD4<Int32>] = []
        var tiles: [TileCoord] = []
        for columns in span.columns {
            regions.append(SIMD4<Int32>(Int32(columns.lowerBound), Int32(span.rows.lowerBound),
                                        Int32(columns.count), Int32(span.rows.count)))
            tiles.append(contentsOf: Self.tiles(columns: columns, rows: span.rows))
        }
        return Prepared(gpu: gpu, regions: regions, tiles: tiles, shape: tip?.shape, grain: tip?.grain)
    }

    private func dispatch(_ prepared: [Prepared], encoder: any MTLComputeCommandEncoder) {
        let group = MTLSize(width: 16, height: 16, depth: 1)
        for item in prepared {
            encoder.setTexture(gpuTexture(item.shape), index: 1)
            encoder.setTexture(gpuTexture(item.grain), index: 2)
            for region in item.regions {
                var gpu = item.gpu
                gpu.region = region
                encoder.setBytes(&gpu, length: MemoryLayout<GPUDab>.stride, index: 0)
                let groups = MTLSize(width: (Int(region.z) + group.width - 1) / group.width,
                                     height: (Int(region.w) + group.height - 1) / group.height, depth: 1)
                encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: group)
            }
        }
    }

    /// Encode les dabs, dans l'ordre, sur `texture` (RGBA16F lecture/écriture). Renvoie les tuiles touchées.
    @discardableResult
    public func encode(_ dabs: [SphericalDab], space: BlendSpace, alphaLock: Bool = false, into texture: any MTLTexture,
                       commandBuffer: any MTLCommandBuffer) -> Set<TileCoord> {
        guard !dabs.isEmpty, let encoder = commandBuffer.makeComputeCommandEncoder() else { return [] }
        let prepared = dabs.map { prepare($0, width: texture.width, height: texture.height, space: space, alphaLock: alphaLock) }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setSamplerState(clampSampler, index: 0)
        encoder.setSamplerState(repeatSampler, index: 1)
        dispatch(prepared, encoder: encoder)
        encoder.endEncoding()
        return Set(prepared.flatMap(\.tiles))
    }

    /// Ajoute des dabs au trait en cours. `known` : tuiles déjà touchées par ce trait (leur copie d'avant et leur masque
    /// existent). Les nouvelles tuiles sont d'abord recopiées de `layer` vers `original` et leur masque remis à zéro ;
    /// puis les dabs s'accumulent dans `mask` et les tuiles touchées sont recalculées dans `layer`. Renvoie ces tuiles.
    @discardableResult
    public func encodeStroke(_ dabs: [SphericalDab], style: StrokeStyle, space: BlendSpace, alphaLock: Bool = false,
                             layer: any MTLTexture, original: any MTLTexture, mask: any MTLTexture, known: Set<TileCoord>,
                             commandBuffer: any MTLCommandBuffer) -> Set<TileCoord> {
        guard !dabs.isEmpty else { return [] }
        let prepared = dabs.map { prepare($0, width: layer.width, height: layer.height, space: space, alphaLock: alphaLock) }
        let touched = Set(prepared.flatMap(\.tiles))
        let fresh = touched.subtracting(known)
        let side = TileSize.side
        if !fresh.isEmpty, let blit = commandBuffer.makeBlitCommandEncoder() {
            for coord in fresh {
                let x = coord.x * side, y = coord.y * side
                guard x < layer.width, y < layer.height else { continue }
                let size = MTLSize(width: min(side, layer.width - x), height: min(side, layer.height - y), depth: 1)
                let origin = MTLOrigin(x: x, y: y, z: 0)
                blit.copy(from: layer, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin, sourceSize: size,
                          to: original, destinationSlice: 0, destinationLevel: 0, destinationOrigin: origin)
                blit.copy(from: zeroTile, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: size,
                          to: mask, destinationSlice: 0, destinationLevel: 0, destinationOrigin: origin)
            }
            blit.endEncoding()
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return [] }
        encoder.setComputePipelineState(maskPipeline)
        encoder.setTexture(mask, index: 0)
        encoder.setSamplerState(clampSampler, index: 0)
        encoder.setSamplerState(repeatSampler, index: 1)
        dispatch(prepared, encoder: encoder)

        // Recalcul des tuiles touchées : une grille de 256 × 256 par tuile (z = index de la tuile).
        var stroke = GPUStroke(color: SIMD4<Float>(style.color.x, style.color.y, style.color.z, style.mode == .erase ? 1 : 0),
                               options: SIMD4<Float>(style.capsPrimary ? 1 : 0, style.capsSecondary ? 1 : 0,
                                                     Float(style.dual?.index ?? -1), space == .linear ? 1 : 0),
                               lock: SIMD4<Float>(alphaLock ? 1 : 0, 0, 0, 0))
        let coords = touched.map { SIMD2<Int32>(Int32($0.x), Int32($0.y)) }
        encoder.setComputePipelineState(applyPipeline)
        encoder.setTexture(layer, index: 0)
        encoder.setTexture(original, index: 1)
        encoder.setTexture(mask, index: 2)
        encoder.setBytes(&stroke, length: MemoryLayout<GPUStroke>.stride, index: 0)
        let bytes = coords.count * MemoryLayout<SIMD2<Int32>>.stride
        if bytes <= 4096 {
            coords.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: bytes, index: 1) }
        } else if let buffer = device.makeBuffer(bytes: coords, length: bytes, options: .storageModeShared) {
            encoder.setBuffer(buffer, offset: 0, index: 1)
        }
        let group = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreadgroups(MTLSize(width: side / 16, height: side / 16, depth: coords.count), threadsPerThreadgroup: group)
        encoder.endEncoding()
        return touched
    }

    /// Remet les tuiles d'un trait dans leur état d'avant le trait (copie `original` → `layer`) et vide leur masque :
    /// le trait peut ensuite être repeint autrement (effilement de fin appliqué au lever).
    public func resetStroke(tiles: Set<TileCoord>, layer: any MTLTexture, original: any MTLTexture, mask: any MTLTexture,
                            commandBuffer: any MTLCommandBuffer) {
        guard !tiles.isEmpty, let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        let side = TileSize.side
        for coord in tiles {
            let x = coord.x * side, y = coord.y * side
            guard x < layer.width, y < layer.height else { continue }
            let size = MTLSize(width: min(side, layer.width - x), height: min(side, layer.height - y), depth: 1)
            let origin = MTLOrigin(x: x, y: y, z: 0)
            blit.copy(from: original, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin, sourceSize: size,
                      to: layer, destinationSlice: 0, destinationLevel: 0, destinationOrigin: origin)
            blit.copy(from: zeroTile, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: size,
                      to: mask, destinationSlice: 0, destinationLevel: 0, destinationOrigin: origin)
        }
        blit.endEncoding()
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
        float4 extra;
        int4 region;
    };

    struct Stroke {
        float4 color;
        float4 options;
        float4 lock;
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

    /// Fusion de deux couvertures : pinceau double et grain (même ordre que `DualBlendMode.allCases`).
    static float combine(int mode, float p, float s) {
        float r;
        switch (mode) {
            case 0: r = p * s; break;
            case 1: r = min(p, s); break;
            case 2: r = p < 0.5 ? 2.0 * p * s : 1.0 - 2.0 * (1.0 - p) * (1.0 - s); break;
            case 3: r = s >= 1.0 ? (p > 0.0 ? 1.0 : 0.0) : p / (1.0 - s); break;
            case 4: r = s <= 0.0 ? 0.0 : 1.0 - (1.0 - p) / s; break;
            case 5: r = p + s - 1.0; break;
            case 6: r = (p + s - 1.0) / 0.1; break;
            default: r = p - s; break;
        }
        return clamp(r, 0.0, 1.0);
    }

    /// Couverture du dab au texel `gid` de sa zone (forme × grain) ; faux si le texel est hors du dab.
    static bool dabTexel(constant Dab& dab, int width, int height, uint2 gid,
                         texture2d<float> shape, texture2d<float> grain, sampler clampSampler, sampler repeatSampler,
                         thread uint2& p, thread float& a) {
        if (gid.x >= uint(dab.region.z) || gid.y >= uint(dab.region.w)) { return false; }
        int x = (dab.region.x + int(gid.x)) % width;
        int y = dab.region.y + int(gid.y);

        float theta = (float(y) + 0.5) / float(height) * PI;
        float phi = ((float(x) + 0.5) / float(width) - 0.5) * 2.0 * PI;
        float s = sin(theta);
        float3 d = float3(s * sin(phi), cos(theta), -s * cos(phi));

        float3 c = dab.center.xyz;
        float cosA = dot(c, d);
        if (cosA < dab.params.z) { return false; }
        float3 tangent = d - c * cosA;
        float sinA = length(tangent);
        float distance = atan2(sinA, cosA);
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
            float qx = (px * dab.tip.x + py * dab.tip.y) / dab.center.w / dab.extra.y;
            if (dab.grain.z > 0.5) { qx = -qx; }
            float qy = (-px * dab.tip.y + py * dab.tip.x) / dab.center.w / max(0.05, dab.grain.w);
            if (abs(qx) > 1.0 || abs(qy) > 1.0) { return false; }
            a = shape.sample(clampSampler, float2((qx + 1.0) * 0.5, (1.0 - qy) * 0.5), level(dab.extra.z)).r;
        } else {
            a = coverage(distance, dab.center.w, dab.params.x, dab.params.y);
        }
        if (a <= 0.0) { return false; }
        if (dab.tip.w > 1.5) {
            // Grain mobile : dans le repère du tampon, tourné et décalé.
            float gu = (px * dab.grain2.z + py * dab.grain2.w) * dab.grain.x + dab.grain2.x;
            float gv = (-px * dab.grain2.w + py * dab.grain2.z) * dab.grain.x + dab.grain2.y;
            float g = grain.sample(repeatSampler, float2(gu, gv), level(dab.extra.w)).r;
            a = combine(int(dab.extra.x), a, 1.0 - dab.grain.y * (1.0 - g));
        } else if (dab.tip.w > 0.5) {
            // Grain fixé à la sphère : trois projections planes mélangées (poids |d|^4).
            float3 w = abs(d);
            w = w * w;
            w = w * w;
            w /= (w.x + w.y + w.z);
            float s = dab.grain.x;
            float g = w.x * grain.sample(repeatSampler, d.yz * s, level(dab.extra.w)).r
                    + w.y * grain.sample(repeatSampler, d.xz * s, level(dab.extra.w)).r
                    + w.z * grain.sample(repeatSampler, d.xy * s, level(dab.extra.w)).r;
            a = combine(int(dab.extra.x), a, 1.0 - dab.grain.y * (1.0 - g));
        }
        p = uint2(x, y);
        return a > 0.0;
    }

    /// Couleur `color` (opacité `sa` déjà multipliée) posée sur `dst` : même calcul que `SphericalRasterizer`.
    static float4 blendOver(float4 dst, float3 color, float sa, bool erase, bool linearSpace) {
        if (erase) { return dst * (1.0 - sa); }
        if (linearSpace) { return float4(color * sa, sa) + dst * (1.0 - sa); }
        float da = dst.w;
        float outA = sa + da * (1.0 - sa);
        if (outA <= 0.0) { return float4(0.0); }
        float3 src = toEncoded3(color);
        float3 below = da > 0.0 ? toEncoded3(dst.rgb / da) : float3(0.0);
        float3 mixed = (src * sa + below * (da * (1.0 - sa))) / outA;
        return float4(toLinear3(mixed) * outA, outA);
    }

    static float4 lockAlpha(float4 dst, float4 original) {
        return (original.w > 0.0 && dst.w > 0.0) ? float4(dst.rgb / dst.w * original.w, original.w) : original;
    }

    kernel void stampDab(texture2d<float, access::read_write> layer [[texture(0)]],
                         texture2d<float> shape [[texture(1)]],
                         texture2d<float> grain [[texture(2)]],
                         sampler clampSampler [[sampler(0)]],
                         sampler repeatSampler [[sampler(1)]],
                         constant Dab& dab [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
        uint2 p;
        float a;
        if (!dabTexel(dab, int(layer.get_width()), int(layer.get_height()), gid, shape, grain, clampSampler, repeatSampler, p, a)) { return; }
        float4 original = layer.read(p);
        float4 dst = blendOver(original, dab.color.rgb, a * dab.color.w, dab.params.w > 0.5, dab.options.x > 0.5);
        if (dab.options.y > 0.5) { dst = lockAlpha(dst, original); }
        layer.write(dst, p);
    }

    /// Accumule le dab dans le masque du trait (voir `StrokeMask.accumulate`).
    kernel void stampMask(texture2d<float, access::read_write> mask [[texture(0)]],
                          texture2d<float> shape [[texture(1)]],
                          texture2d<float> grain [[texture(2)]],
                          sampler clampSampler [[sampler(0)]],
                          sampler repeatSampler [[sampler(1)]],
                          constant Dab& dab [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
        uint2 p;
        float a;
        if (!dabTexel(dab, int(mask.get_width()), int(mask.get_height()), gid, shape, grain, clampSampler, repeatSampler, p, a)) { return; }
        float4 m = mask.read(p);
        float o = a * dab.color.w;
        float f = o * dab.options.w;
        if (dab.options.z > 0.5) {
            m.z += f * (1.0 - m.z);
            m.w = max(m.w, o);
        } else {
            m.x += f * (1.0 - m.x);
            m.y = max(m.y, o);
        }
        mask.write(m, p);
    }

    /// Pose le trait : l'original d'avant le trait, avec la couleur à l'opacité du masque (voir `StrokeMask.composite`).
    kernel void applyStroke(texture2d<float, access::read_write> layer [[texture(0)]],
                            texture2d<float> original [[texture(1)]],
                            texture2d<float> mask [[texture(2)]],
                            constant Stroke& stroke [[buffer(0)]],
                            constant int2* tiles [[buffer(1)]],
                            uint3 gid [[thread_position_in_grid]]) {
        int2 tile = tiles[gid.z];
        uint2 p = uint2(uint(tile.x) * 256u + gid.x, uint(tile.y) * 256u + gid.y);
        if (p.x >= layer.get_width() || p.y >= layer.get_height()) { return; }
        float4 m = mask.read(p);
        float4 before = original.read(p);
        float alpha = stroke.options.x > 0.5 ? min(m.x, m.y) : m.x;
        int dual = int(stroke.options.z);
        if (dual >= 0) {
            float s = stroke.options.y > 0.5 ? min(m.z, m.w) : m.z;
            alpha = combine(dual, alpha, s);
        }
        float4 dst = before;
        if (alpha > 0.0) {
            dst = blendOver(before, stroke.color.rgb, alpha, stroke.color.w > 0.5, stroke.options.w > 0.5);
            if (stroke.lock.x > 0.5) { dst = lockAlpha(dst, before); }
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
