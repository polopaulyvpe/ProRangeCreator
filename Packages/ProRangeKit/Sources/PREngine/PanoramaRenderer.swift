import Metal
import PRCore

/// Uniformes du shader de panorama (même disposition que `ViewUniforms` en MSL : huit `float4`).
public struct ViewUniforms {
    public var rot0: SIMD4<Float>
    public var rot1: SIMD4<Float>
    public var rot2: SIMD4<Float>
    public var shiftTan: SIMD4<Float>
    public var unfolded: SIMD4<Float>
    public var display: SIMD4<Float>
    public var background: SIMD4<Float>
    public var paper: SIMD4<Float>

    public init(_ p: ProjectionParameters, viewportHeight: Int, textureHeight: Int,
                exposure: Double = 0, toneMapping: ToneMapping = .clip, background: SIMD3<Float> = [0.08, 0.08, 0.09],
                paper: SIMD3<Float> = [1, 1, 1]) {
        self.paper = [paper.x, paper.y, paper.z, 1]
        func column(_ c: SIMD3<Double>) -> SIMD4<Float> { [Float(c.x), Float(c.y), Float(c.z), 0] }
        rot0 = column(p.rotation.columns.0)
        rot1 = column(p.rotation.columns.1)
        rot2 = column(p.rotation.columns.2)
        shiftTan = [Float(p.shift.x), Float(p.shift.y), Float(p.tanHalfFov), Float(p.aspect)]
        unfolded = [Float(p.unfoldedCenter.x), Float(p.unfoldedCenter.y), Float(p.unfoldedSpan), Float(p.morph)]
        display = [Float(exposure), Float(toneMapping.rawValue), Float(viewportHeight), Float(textureHeight)]
        self.background = [background.x, background.y, background.z, 1]
    }
}

/// Dessine le panorama équirectangulaire selon la vue (sphère, dépliée, fenêtre plane, morphing).
public final class PanoramaRenderer {
    public enum Filtering {
        /// Bilinéaire + mipmaps (affichage).
        case linear
        /// Plus proche voisin, sans mipmap (tests au pixel près).
        case nearest
    }

    public enum Failure: Error {
        case noDevice
        case commandFailed
    }

    public let device: any MTLDevice
    private let library: any MTLLibrary
    private let linearSampler: any MTLSamplerState
    private let nearestSampler: any MTLSamplerState
    private var pipelines: [MTLPixelFormat: any MTLRenderPipelineState] = [:]

    public init(device: any MTLDevice) throws {
        self.device = device
        library = try device.makeLibrary(source: PanoramaShaders.source, options: nil)
        linearSampler = try Self.makeSampler(device: device, filter: .linear)
        nearestSampler = try Self.makeSampler(device: device, filter: .nearest)
    }

    private static func makeSampler(device: any MTLDevice, filter: MTLSamplerMinMagFilter) throws -> any MTLSamplerState {
        let desc = MTLSamplerDescriptor()
        desc.minFilter = filter
        desc.magFilter = filter
        desc.mipFilter = filter == .linear ? .linear : .notMipmapped
        desc.sAddressMode = .repeat       // la longitude boucle sur la couture
        desc.tAddressMode = .clampToEdge  // pas de bouclage aux pôles
        guard let sampler = device.makeSamplerState(descriptor: desc) else { throw Failure.noDevice }
        return sampler
    }

    private func pipeline(for format: MTLPixelFormat) throws -> any MTLRenderPipelineState {
        if let cached = pipelines[format] { return cached }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "panoramaVertex")
        desc.fragmentFunction = library.makeFunction(name: "panoramaFragment")
        desc.colorAttachments[0].pixelFormat = format
        let state = try device.makeRenderPipelineState(descriptor: desc)
        pipelines[format] = state
        return state
    }

    /// Encode le dessin du panorama dans une passe de rendu déjà ouverte.
    public func encode(into encoder: any MTLRenderCommandEncoder, pixelFormat: MTLPixelFormat,
                       panorama: any MTLTexture, uniforms: ViewUniforms, filtering: Filtering = .linear) throws {
        var u = uniforms
        encoder.setRenderPipelineState(try pipeline(for: pixelFormat))
        encoder.setFragmentBytes(&u, length: MemoryLayout<ViewUniforms>.stride, index: 0)
        encoder.setFragmentTexture(panorama, index: 0)
        encoder.setFragmentSamplerState(filtering == .linear ? linearSampler : nearestSampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// Rendu hors écran en RGBA16F, relu sur le CPU (tests, export d'aperçu).
    public func renderOffscreen(panorama: any MTLTexture, width: Int, height: Int,
                                uniforms: ViewUniforms, filtering: Filtering = .linear) throws -> [Float16] {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc),
              let queue = device.makeCommandQueue(),
              let commands = queue.makeCommandBuffer() else { throw Failure.noDevice }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.commandFailed }
        try encode(into: encoder, pixelFormat: .rgba16Float, panorama: panorama, uniforms: uniforms, filtering: filtering)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { throw Failure.commandFailed }
        var out = [Float16](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return out
    }
}
