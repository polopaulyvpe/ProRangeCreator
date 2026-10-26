import Metal
import PRCore
import PRStorage
import simd

/// Une opération du panneau Ajustements.
public enum FilterOperation: Equatable, Sendable {
    case adjustment(Adjustment)
    case filter(SphereFilter)

    public var label: String {
        switch self {
        case .adjustment(let a): a.label
        case .filter(let f): f.label
        }
    }
}

/// Ajustements et filtres sur GPU, sur une texture pleine résolution d'un calque (RGBA16F linéaire prémultiplié).
/// Mêmes calculs que les références CPU (`Adjustment.apply`, `FilterReference`), testés contre elles.
public final class FilterEngine {
    public enum Failure: Error {
        case noFunction(String)
        case allocationFailed
        case commandFailed
    }

    struct Params {
        var a: SIMD4<Float> = .zero
        var b: SIMD4<Float> = .zero
        var c: SIMD4<Float> = .zero
        var d: SIMD4<Float> = .zero
        var mode: SIMD4<Int32> = .zero
    }

    public let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private var pipelines: [String: any MTLComputePipelineState] = [:]
    private let library: any MTLLibrary
    private let linearSampler: any MTLSamplerState
    private var temporaries: [(any MTLTexture)] = []

    public init(device: any MTLDevice) throws {
        self.device = device
        library = try device.makeLibrary(source: Self.source, options: nil)
        guard let queue = device.makeCommandQueue() else { throw Failure.allocationFailed }
        self.queue = queue
        let desc = MTLSamplerDescriptor()
        desc.minFilter = .linear
        desc.magFilter = .linear
        desc.sAddressMode = .repeat
        desc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: desc) else { throw Failure.allocationFailed }
        linearSampler = sampler
    }

    private func pipeline(_ name: String) throws -> any MTLComputePipelineState {
        if let cached = pipelines[name] { return cached }
        guard let function = library.makeFunction(name: name) else { throw Failure.noFunction(name) }
        let state = try device.makeComputePipelineState(function: function)
        pipelines[name] = state
        return state
    }

    public func makeTexture(width: Int, height: Int) throws -> any MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { throw Failure.allocationFailed }
        return texture
    }

    /// Copie un calque (16 bits flottants) dans une nouvelle texture.
    public func upload(_ layer: TiledLayer) throws -> any MTLTexture {
        let texture = try makeTexture(width: layer.width, height: layer.height)
        let side = TileSize.side
        let zeros = [UInt8](repeating: 0, count: TileSize.pixelCount * 8)
        for ty in 0..<layer.tilesDown {
            for tx in 0..<layer.tilesAcross {
                let coord = TileCoord(x: tx, y: ty)
                let bytes = layer.isStored(coord) && layer.format == .rgba16Float ? layer.tileBytes(coord) : zeros
                bytes.withUnsafeBytes { raw in
                    texture.replace(region: MTLRegionMake2D(tx * side, ty * side, side, side), mipmapLevel: 0,
                                    withBytes: raw.baseAddress!, bytesPerRow: side * 8)
                }
            }
        }
        return texture
    }

    private func temporary(_ index: Int, like source: any MTLTexture) throws -> any MTLTexture {
        while temporaries.count <= index { temporaries.append(try makeTexture(width: source.width, height: source.height)) }
        if temporaries[index].width != source.width || temporaries[index].height != source.height {
            temporaries[index] = try makeTexture(width: source.width, height: source.height)
        }
        return temporaries[index]
    }

    /// Exécute l'opération de `source` vers `destination` (même taille) et attend le GPU.
    public func run(_ operation: FilterOperation, source: any MTLTexture, destination: any MTLTexture) throws {
        guard let commands = queue.makeCommandBuffer() else { throw Failure.commandFailed }
        try encode(operation, source: source, destination: destination, commands: commands)
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { throw Failure.commandFailed }
    }

    private func dispatch(_ name: String, _ params: Params, textures: [any MTLTexture], size: (Int, Int),
                          lut: [Float]? = nil, commands: any MTLCommandBuffer) throws {
        guard let encoder = commands.makeComputeCommandEncoder() else { throw Failure.commandFailed }
        encoder.setComputePipelineState(try pipeline(name))
        for (i, t) in textures.enumerated() { encoder.setTexture(t, index: i) }
        var p = params
        encoder.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        var table = lut ?? [0]
        encoder.setBytes(&table, length: MemoryLayout<Float>.stride * table.count, index: 1)
        encoder.setSamplerState(linearSampler, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreadgroups(MTLSize(width: (size.0 + 15) / 16, height: (size.1 + 15) / 16, depth: 1), threadsPerThreadgroup: group)
        encoder.endEncoding()
    }

    private func encodeBlur(sigma: Double, source: any MTLTexture, destination: any MTLTexture, commands: any MTLCommandBuffer) throws {
        let size = (source.width, source.height)
        let sigmaPixels = Float(sigma / (Double.pi / Double(source.height)))
        let middle = try temporary(0, like: source)
        var p = Params()
        p.a = [sigmaPixels, Float(source.width) / 6, 0, 0]
        try dispatch("blurHorizontal", p, textures: [source, middle], size: size, commands: commands)
        try dispatch("blurVertical", p, textures: [middle, destination], size: size, commands: commands)
    }

    public func encode(_ operation: FilterOperation, source: any MTLTexture, destination: any MTLTexture,
                       commands: any MTLCommandBuffer) throws {
        let size = (source.width, source.height)
        var p = Params()
        switch operation {
        case .adjustment(let adjustment):
            var lut: [Float]?
            switch adjustment {
            case let .hueSaturation(hue, saturation, brightness):
                p.mode.x = 0
                p.a = [Float(hue), Float(saturation), Float(brightness), 0]
            case let .colorBalance(shadows, midtones, highlights):
                p.mode.x = 1
                p.a = SIMD4<Float>(SIMD3<Float>(shadows), 0)
                p.b = SIMD4<Float>(SIMD3<Float>(midtones), 0)
                p.c = SIMD4<Float>(SIMD3<Float>(highlights), 0)
            case let .curves(curve):
                p.mode.x = 2
                // 512 valeurs : sous la limite de 4 Ko des données passées directement au kernel.
                let table = curve.table(count: 512)
                // Prolongement linéaire au-delà du domaine : la pente de la dernière section de la table.
                p.a = [Float(curve.maxInput), Float(table.count), 0, 0]
                lut = table
            case let .gradientMap(dark, light):
                p.mode.x = 3
                p.a = SIMD4<Float>(SIMD3<Float>(dark), 0)
                p.b = SIMD4<Float>(SIMD3<Float>(light), 0)
            case let .recolor(from, to, tolerance):
                p.mode.x = 4
                p.a = [Float(from), Float(to), Float(tolerance), 0]
            }
            try dispatch("adjust", p, textures: [source, destination], size: size, lut: lut, commands: commands)

        case .filter(let filter):
            switch filter {
            case .gaussianBlur(let radius):
                try encodeBlur(sigma: radius, source: source, destination: destination, commands: commands)
            case let .motionBlur(length, angle):
                p.a = [Float(length), Float(angle), Float(Double.pi / Double(source.height)), 0]
                try dispatch("motionBlur", p, textures: [source, destination], size: size, commands: commands)
            case let .noise(amount, cell, seed, monochrome):
                p.a = [Float(amount), Float(cell), 0, 0]
                p.mode = [Int32(bitPattern: seed), monochrome ? 1 : 0, 0, 0]
                try dispatch("noise", p, textures: [source, destination], size: size, commands: commands)
            case let .sharpen(radius, amount):
                let blurred = try temporary(1, like: source)
                try encodeBlur(sigma: radius, source: source, destination: blurred, commands: commands)
                p.a = [Float(amount), 0, 0, 0]
                try dispatch("sharpenCombine", p, textures: [source, blurred, destination], size: size, commands: commands)
            case let .bloom(threshold, radius, intensity):
                let bright = try temporary(1, like: source)
                let blurred = try temporary(2, like: source)
                p.a = [Float(threshold), Float(intensity), 0, 0]
                try dispatch("bloomThreshold", p, textures: [source, bright], size: size, commands: commands)
                try encodeBlur(sigma: radius, source: bright, destination: blurred, commands: commands)
                try dispatch("bloomAdd", p, textures: [source, blurred, destination], size: size, commands: commands)
            case let .chromaticAberration(center, strength):
                let frame = TangentFrame(center: center)
                p.a = SIMD4<Float>(SIMD3<Float>(frame.center), Float(strength))
                p.b = SIMD4<Float>(SIMD3<Float>(frame.east), 0)
                p.c = SIMD4<Float>(SIMD3<Float>(frame.north), 0)
                try dispatch("chromatic", p, textures: [source, destination], size: size, commands: commands)
            }
        }
    }

    /// Relit le résultat dans le calque (opération enregistrée, limitée à la sélection s'il y en a une).
    public func readBack(_ texture: any MTLTexture, into layer: TiledLayer, selection: SelectionMask?) -> [TileDelta] {
        let side = TileSize.side
        var bytes = [UInt8](repeating: 0, count: TileSize.pixelCount * 8)
        var touched = Set<TileCoord>()
        layer.beginOperation()
        for ty in 0..<layer.tilesDown {
            for tx in 0..<layer.tilesAcross {
                let coord = TileCoord(x: tx, y: ty)
                bytes.withUnsafeMutableBytes { raw in
                    texture.getBytes(raw.baseAddress!, bytesPerRow: side * 8,
                                     from: MTLRegionMake2D(tx * side, ty * side, side, side), mipmapLevel: 0)
                }
                if layer.isStored(coord) || bytes.contains(where: { $0 != 0 }) {
                    layer.replaceTile(coord, with: bytes)
                    touched.insert(coord)
                }
            }
        }
        if let selection { layer.constrainCurrentOperation(to: selection, tiles: touched) }
        return layer.endOperation()
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    constant float PI = 3.14159265358979;
    constant float SLOPE_AT_ONE = 1.055 / 2.4;

    struct Params {
        float4 a;
        float4 b;
        float4 c;
        float4 d;
        int4 mode;
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

    static float3 directionAt(uint2 gid, uint width, uint height) {
        float theta = (float(gid.y) + 0.5) / float(height) * PI;
        float phi = ((float(gid.x) + 0.5) / float(width) - 0.5) * 2.0 * PI;
        float s = sin(theta);
        return float3(s * sin(phi), cos(theta), -s * cos(phi));
    }
    static float2 uvOf(float3 d) {
        return float2(atan2(d.x, -d.z) / (2.0 * PI) + 0.5, acos(clamp(d.y, -1.0, 1.0)) / PI);
    }

    // HSB (PRCore.HSBColor).
    static float3 toHSB(float3 c) {
        float mx = max(max(c.x, c.y), c.z);
        float mn = min(min(c.x, c.y), c.z);
        float delta = mx - mn;
        float h = 0.0;
        if (delta > 0.0) {
            if (mx == c.x) { h = (c.y - c.z) / delta; }
            else if (mx == c.y) { h = 2.0 + (c.z - c.x) / delta; }
            else { h = 4.0 + (c.x - c.y) / delta; }
            h /= 6.0;
            if (h < 0.0) { h += 1.0; }
        }
        return float3(h, mx > 0.0 ? delta / mx : 0.0, mx);
    }
    static float3 fromHSB(float3 hsb) {
        float h = (hsb.x - floor(hsb.x)) * 6.0;
        int sector = int(h) % 6;
        float f = h - floor(h);
        float v = hsb.z, s = hsb.y;
        float p = v * (1.0 - s), q = v * (1.0 - s * f), t = v * (1.0 - s * (1.0 - f));
        switch (sector) {
            case 0: return float3(v, t, p);
            case 1: return float3(q, v, p);
            case 2: return float3(p, v, t);
            case 3: return float3(p, q, v);
            case 4: return float3(t, p, v);
            default: return float3(v, p, q);
        }
    }

    static float curveValue(float x, constant Params& p, constant float* lut) {
        float maxInput = p.a.x;
        int count = int(p.a.y);
        float position = x / maxInput * float(count - 1);
        if (position <= 0.0) { return lut[0] + position * (lut[1] - lut[0]); }
        if (position >= float(count - 1)) {
            return lut[count - 1] + (position - float(count - 1)) * (lut[count - 1] - lut[count - 2]);
        }
        int i = int(position);
        return mix(lut[i], lut[i + 1], position - float(i));
    }

    kernel void adjust(texture2d<float, access::read> source [[texture(0)]],
                       texture2d<float, access::write> destination [[texture(1)]],
                       constant Params& p [[buffer(0)]],
                       constant float* lut [[buffer(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) { return; }
        float4 px = source.read(gid);
        if (px.w <= 0.0) { destination.write(px, gid); return; }
        float3 c = toEncoded3(px.rgb / px.w);
        switch (p.mode.x) {
            case 0: {
                float peak = max(1.0, max(max(c.x, c.y), c.z));
                float3 hsb = toHSB(c / peak);
                hsb.x = fract(hsb.x + p.a.x + 1.0);
                hsb.y = clamp(hsb.y * (1.0 + p.a.y), 0.0, 1.0);
                hsb.z = max(0.0, hsb.z * (1.0 + p.a.z));
                c = fromHSB(hsb) * peak;
                break;
            }
            case 1: {
                float l = clamp(0.3 * c.x + 0.59 * c.y + 0.11 * c.z, 0.0, 1.0);
                float sw = max(0.0, 1.0 - l * 2.0);
                float hw = max(0.0, l * 2.0 - 1.0);
                float mw = 1.0 - sw - hw;
                c += (p.a.xyz * sw + p.b.xyz * mw + p.c.xyz * hw) * 0.25;
                break;
            }
            case 2:
                c = float3(curveValue(c.x, p, lut), curveValue(c.y, p, lut), curveValue(c.z, p, lut));
                break;
            case 3: {
                float l = 0.3 * c.x + 0.59 * c.y + 0.11 * c.z;
                c = p.a.xyz + (p.b.xyz - p.a.xyz) * l;
                break;
            }
            default: {
                float peak = max(1.0, max(max(c.x, c.y), c.z));
                float3 hsb = toHSB(c / peak);
                float distance = abs(hsb.x - p.a.x);
                distance = min(distance, 1.0 - distance);
                if (hsb.y > 0.05 && distance < p.a.z) {
                    float weight = 1.0 - distance / p.a.z;
                    float shift = p.a.y - p.a.x;
                    shift -= rint(shift);
                    hsb.x = fract(hsb.x + shift * weight + 1.0);
                    c = fromHSB(hsb) * peak;
                }
                break;
            }
        }
        float3 l = toLinear3(max(c, 0.0)) * px.w;
        destination.write(float4(l, px.w), gid);
    }

    // Flou gaussien séparable (FilterReference.separableBlur) : horizontal divisé par cos(latitude), longitude bouclée.
    kernel void blurHorizontal(texture2d<float, access::read> source [[texture(0)]],
                               texture2d<float, access::write> destination [[texture(1)]],
                               constant Params& p [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
        int width = int(destination.get_width());
        int height = int(destination.get_height());
        if (int(gid.x) >= width || int(gid.y) >= height) { return; }
        float lat = (0.5 - (float(gid.y) + 0.5) / float(height)) * PI;
        float sigma = min(p.a.y, p.a.x / max(cos(lat), 1e-4));
        int radius = max(1, int(ceil(3.0 * sigma)));
        int step = max(1, (radius + 63) / 64);
        float4 sum = float4(0.0);
        float total = 0.0;
        for (int offset = -(radius / step) * step; offset <= radius; offset += step) {
            float w = exp(-0.5 * (float(offset) / sigma) * (float(offset) / sigma));
            int x = ((int(gid.x) + offset) % width + width) % width;
            sum += source.read(uint2(x, gid.y)) * w;
            total += w;
        }
        destination.write(sum / total, gid);
    }

    kernel void blurVertical(texture2d<float, access::read> source [[texture(0)]],
                             texture2d<float, access::write> destination [[texture(1)]],
                             constant Params& p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        int width = int(destination.get_width());
        int height = int(destination.get_height());
        if (int(gid.x) >= width || int(gid.y) >= height) { return; }
        float sigma = p.a.x;
        int radius = max(1, int(ceil(3.0 * sigma)));
        int step = max(1, (radius + 63) / 64);
        float4 sum = float4(0.0);
        float total = 0.0;
        for (int offset = -(radius / step) * step; offset <= radius; offset += step) {
            float w = exp(-0.5 * (float(offset) / sigma) * (float(offset) / sigma));
            int y = clamp(int(gid.y) + offset, 0, height - 1);
            sum += source.read(uint2(gid.x, y)) * w;
            total += w;
        }
        destination.write(sum / total, gid);
    }

    // Flou de mouvement : moyenne le long du grand cercle tangent, orienté de `angle` depuis l'est local.
    kernel void motionBlur(texture2d<float, access::sample> source [[texture(0)]],
                           texture2d<float, access::write> destination [[texture(1)]],
                           constant Params& p [[buffer(0)]],
                           sampler s [[sampler(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        uint width = destination.get_width(), height = destination.get_height();
        if (gid.x >= width || gid.y >= height) { return; }
        float3 d = directionAt(gid, width, height);
        float3 east = cross(d, float3(0.0, 1.0, 0.0));
        east = length(east) < 1e-6 ? float3(1.0, 0.0, 0.0) : normalize(east);
        float3 north = cross(east, d);
        float3 t = east * cos(p.a.y) + north * sin(p.a.y);
        int samples = clamp(int(ceil(p.a.x / p.a.z)), 1, 64);
        float4 sum = float4(0.0);
        for (int i = 0; i <= samples; i++) {
            float a = (float(i) / float(samples) - 0.5) * p.a.x;
            sum += source.sample(s, uvOf(d * cos(a) + t * sin(a)), level(0.0));
        }
        destination.write(sum / float(samples + 1), gid);
    }

    // Bruit sphérique (PRCore.SphericalNoise) : cellules d'un réseau 3D.
    static float noiseHash(int3 q, uint seed) {
        uint h = uint(q.x) * 0x8DA6B343u;
        h ^= uint(q.y) * 0xD8163841u;
        h ^= uint(q.z) * 0xCB1AB31Fu;
        h ^= seed;
        h ^= h >> 16; h *= 0x7FEB352Du;
        h ^= h >> 15; h *= 0x846CA68Bu;
        h ^= h >> 16;
        return float(h >> 8) / 16777216.0;
    }

    kernel void noise(texture2d<float, access::read> source [[texture(0)]],
                      texture2d<float, access::write> destination [[texture(1)]],
                      constant Params& p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
        uint width = destination.get_width(), height = destination.get_height();
        if (gid.x >= width || gid.y >= height) { return; }
        float4 px = source.read(gid);
        if (px.w <= 0.0) { destination.write(px, gid); return; }
        float3 d = directionAt(gid, width, height);
        int3 q = int3(floor(d / p.a.y));
        uint seed = uint(p.mode.x);
        float3 n;
        for (int k = 0; k < 3; k++) {
            uint channel = p.mode.y == 1 ? 0u : uint(k);
            n[k] = noiseHash(q, seed + channel * 0x9E3779B9u);
        }
        float3 e = toEncoded3(px.rgb / px.w) + (n - 0.5) * (2.0 * p.a.x);
        destination.write(float4(toLinear3(max(e, 0.0)) * px.w, px.w), gid);
    }

    kernel void sharpenCombine(texture2d<float, access::read> original [[texture(0)]],
                               texture2d<float, access::read> blurred [[texture(1)]],
                               texture2d<float, access::write> destination [[texture(2)]],
                               constant Params& p [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) { return; }
        float4 o = original.read(gid);
        float4 b = blurred.read(gid);
        float4 r = o + (o - b) * p.a.x;
        destination.write(float4(max(r.rgb, 0.0), clamp(r.w, 0.0, 1.0)), gid);
    }

    kernel void bloomThreshold(texture2d<float, access::read> source [[texture(0)]],
                               texture2d<float, access::write> destination [[texture(1)]],
                               constant Params& p [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) { return; }
        float4 px = source.read(gid);
        destination.write(float4(max(px.rgb - p.a.x * px.w, 0.0), 0.0), gid);
    }

    kernel void bloomAdd(texture2d<float, access::read> original [[texture(0)]],
                         texture2d<float, access::read> blurred [[texture(1)]],
                         texture2d<float, access::write> destination [[texture(2)]],
                         constant Params& p [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) { return; }
        float4 o = original.read(gid);
        float3 glow = blurred.read(gid).rgb * p.a.y;
        float alpha = max(o.w, clamp(max(max(glow.x, glow.y), glow.z), 0.0, 1.0));
        destination.write(float4(o.rgb + glow, alpha), gid);
    }

    // Aberration chromatique (FilterReference.chromaticAberration) : plan tangent azimutal équidistant au centre.
    static float3 unprojectAt(float2 q, float3 c, float3 east, float3 north) {
        float a = length(q);
        if (a < 1e-7) { return c; }
        return c * cos(a) + (east * q.x + north * q.y) / a * sin(a);
    }

    kernel void chromatic(texture2d<float, access::sample> source [[texture(0)]],
                          texture2d<float, access::write> destination [[texture(1)]],
                          constant Params& p [[buffer(0)]],
                          sampler s [[sampler(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
        uint width = destination.get_width(), height = destination.get_height();
        if (gid.x >= width || gid.y >= height) { return; }
        float3 d = directionAt(gid, width, height);
        float3 c = p.a.xyz;
        float cosA = dot(c, d);
        float3 t = d - c * cosA;
        float sinA = length(t);
        float2 q = float2(0.0);
        if (sinA > 1e-7) { q = float2(dot(t, p.b.xyz), dot(t, p.c.xyz)) * (atan2(sinA, cosA) / sinA); }
        float k = p.a.w;
        float4 red = source.sample(s, uvOf(unprojectAt(q / (1.0 + k), c, p.b.xyz, p.c.xyz)), level(0.0));
        float4 green = source.sample(s, uvOf(d), level(0.0));
        float4 blue = source.sample(s, uvOf(unprojectAt(q / (1.0 - k), c, p.b.xyz, p.c.xyz)), level(0.0));
        destination.write(float4(red.x, green.y, blue.z, green.w), gid);
    }
    """
}
