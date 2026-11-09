import Metal
import simd
import PRCore

/// Uniformes du shader de panorama (même disposition que `ViewUniforms` en MSL : trente-cinq `float4`).
public struct ViewUniforms {
    public var rot0: SIMD4<Float>
    public var rot1: SIMD4<Float>
    public var rot2: SIMD4<Float>
    public var shiftTan: SIMD4<Float>
    public var unfolded: SIMD4<Float>
    public var display: SIMD4<Float>
    public var background: SIMD4<Float>
    public var paper: SIMD4<Float>
    /// Calque actif : opacité (0 = pas de calque actif séparé), code du mode, dessus présent, espace de fusion.
    public var layer: SIMD4<Float> = .zero
    /// Aperçu de rotation de la sphère (inverse, en colonnes ; w = 1 si actif).
    public var contentRot0: SIMD4<Float> = .zero
    public var contentRot1: SIMD4<Float> = .zero
    public var contentRot2: SIMD4<Float> = .zero
    /// Guides : actifs, espacement en degrés, opacité.
    public var guides: SIMD4<Float> = .zero
    /// Sélection affichée, aperçu de transformation actif.
    public var selection: SIMD4<Float> = .zero
    public var tCenter: SIMD4<Float> = .zero
    public var tEast: SIMD4<Float> = .zero
    public var tNorth: SIMD4<Float> = .zero
    public var tMoveInv0: SIMD4<Float> = .zero
    public var tMoveInv1: SIMD4<Float> = .zero
    public var tMoveInv2: SIMD4<Float> = .zero
    public var tParams: SIMD4<Float> = .zero
    public var tH0: SIMD4<Float> = .zero
    public var tH1: SIMD4<Float> = .zero
    public var tH2: SIMD4<Float> = .zero
    public var tS0: SIMD4<Float> = .zero
    public var tS1: SIMD4<Float> = .zero
    public var tMisc: SIMD4<Float> = .zero
    // Maillage : `float4 tMesh[8]` en MSL.
    public var tMesh0: SIMD4<Float> = .zero
    public var tMesh1: SIMD4<Float> = .zero
    public var tMesh2: SIMD4<Float> = .zero
    public var tMesh3: SIMD4<Float> = .zero
    public var tMesh4: SIMD4<Float> = .zero
    public var tMesh5: SIMD4<Float> = .zero
    public var tMesh6: SIMD4<Float> = .zero
    public var tMesh7: SIMD4<Float> = .zero

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

    /// Montre le contenu tourné de `rotation` sans toucher aux pixels (nil = pas d'aperçu).
    /// `activeOnly` : seul le calque actif tourne (il faut qu'il soit composé à part : chemin rapide de `StackCanvas`).
    public mutating func setContentRotation(_ rotation: simd_double3x3?, activeOnly: Bool = false) {
        guard let rotation else {
            contentRot0 = .zero
            return
        }
        let inverse = rotation.transpose
        func column(_ c: SIMD3<Double>, _ w: Float) -> SIMD4<Float> { [Float(c.x), Float(c.y), Float(c.z), w] }
        contentRot0 = column(inverse.columns.0, 1)
        contentRot1 = column(inverse.columns.1, activeOnly ? 1 : 0)
        contentRot2 = column(inverse.columns.2, 0)
    }

    /// Sélection affichée (le reste est hachuré, les hachures défilent avec `time` en secondes) et aperçu de la
    /// transformation libre du contenu flottant (`filter` : plus proche voisin ou bilinéaire ; bicubique montré en bilinéaire).
    public mutating func setSelection(visible: Bool, freeTransform: FreeTransform?, time: Double = 0,
                                      filter: ResamplingFilter = .bilinear) {
        let phase = Float(time.truncatingRemainder(dividingBy: 1000))
        guard let transform = freeTransform, let resolved = transform.resolved() else {
            selection = [visible ? 1 : 0, 0, 0, phase]
            return
        }
        selection = [visible ? 1 : 0, 1, 0, phase]
        func vector(_ v: SIMD3<Double>) -> SIMD4<Float> { [Float(v.x), Float(v.y), Float(v.z), 0] }
        tCenter = vector(resolved.frame.center)
        tEast = vector(resolved.frame.east)
        tNorth = vector(resolved.frame.north)
        let moveInverse = resolved.move.transpose
        tMoveInv0 = vector(moveInverse.columns.0)
        tMoveInv1 = vector(moveInverse.columns.1)
        tMoveInv2 = vector(moveInverse.columns.2)
        let h = resolved.inverseHomography
        tH0 = vector(h.columns.0)
        tH1 = vector(h.columns.1)
        tH2 = vector(h.columns.2)
        tS0 = [Float(transform.sourceOrigin.x), Float(transform.sourceOrigin.y), Float(transform.sourceX.x), Float(transform.sourceX.y)]
        tS1 = [Float(transform.sourceY.x), Float(transform.sourceY.y), transform.plane == .equidistant ? 1 : 0,
               resolved.meshIsIdentity ? 0 : 1]
        tMisc = [Float(resolved.sign), filter == .nearest ? 0 : 1, 0, 0]
        let p = transform.mesh.points.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        func pair(_ k: Int) -> SIMD4<Float> { [p[2 * k].x, p[2 * k].y, p[2 * k + 1].x, p[2 * k + 1].y] }
        (tMesh0, tMesh1, tMesh2, tMesh3) = (pair(0), pair(1), pair(2), pair(3))
        (tMesh4, tMesh5, tMesh6, tMesh7) = (pair(4), pair(5), pair(6), pair(7))
    }

    /// Sélection affichée et aperçu d'une transformation par déplacement, échelle et rotation.
    public mutating func setSelection(visible: Bool, transform: SphericalTransform?) {
        setSelection(visible: visible, freeTransform: transform.map { FreeTransform($0) })
    }

    /// Aperçu d'une distorsion par quatre coins du contenu flottant.
    public mutating func setSelection(visible: Bool, distort: SphericalDistort) {
        setSelection(visible: visible, freeTransform: FreeTransform(distort))
    }

    public mutating func setGuides(enabled: Bool, spacingDegrees: Double = 15, opacity: Double = 0.45) {
        guides = [enabled ? 1 : 0, Float(spacingDegrees), Float(opacity), 0]
    }

    /// Décrit la composition à faire dans le shader.
    public mutating func setLayers(activeOpacity: Float, mode: BlendMode, aboveEnabled: Bool, space: BlendSpace) {
        layer = [activeOpacity, Float(mode.code), aboveEnabled ? 1 : 0, space == .linear ? 1 : 0]
    }
}

/// Les textures que le shader compose : dessous (papier compris), calque actif, dessus.
public struct PanoramaLayers {
    public var below: any MTLTexture
    public var active: (any MTLTexture)?
    public var above: (any MTLTexture)?
    public var selection: (any MTLTexture)?
    public var floating: (any MTLTexture)?

    public init(below: any MTLTexture, active: (any MTLTexture)? = nil, above: (any MTLTexture)? = nil) {
        self.below = below
        self.active = active
        self.above = above
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
    private let emptyTexture: any MTLTexture
    private var pipelines: [MTLPixelFormat: any MTLRenderPipelineState] = [:]

    public init(device: any MTLDevice) throws {
        self.device = device
        library = try device.makeLibrary(source: PanoramaShaders.source, options: nil)
        linearSampler = try Self.makeSampler(device: device, filter: .linear)
        nearestSampler = try Self.makeSampler(device: device, filter: .nearest)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let empty = device.makeTexture(descriptor: desc) else { throw Failure.noDevice }
        emptyTexture = empty
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
                       layers: PanoramaLayers, uniforms: ViewUniforms, filtering: Filtering = .linear) throws {
        var u = uniforms
        encoder.setRenderPipelineState(try pipeline(for: pixelFormat))
        encoder.setFragmentBytes(&u, length: MemoryLayout<ViewUniforms>.stride, index: 0)
        encoder.setFragmentTexture(layers.below, index: 0)
        encoder.setFragmentTexture(layers.active ?? emptyTexture, index: 1)
        encoder.setFragmentTexture(layers.above ?? emptyTexture, index: 2)
        encoder.setFragmentTexture(layers.selection ?? emptyTexture, index: 3)
        encoder.setFragmentTexture(layers.floating ?? emptyTexture, index: 4)
        encoder.setFragmentSamplerState(filtering == .linear ? linearSampler : nearestSampler, index: 0)
        encoder.setFragmentSamplerState(nearestSampler, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// Un seul panorama (sans calque actif séparé).
    public func encode(into encoder: any MTLRenderCommandEncoder, pixelFormat: MTLPixelFormat,
                       panorama: any MTLTexture, uniforms: ViewUniforms, filtering: Filtering = .linear) throws {
        var u = uniforms
        u.layer = .zero
        try encode(into: encoder, pixelFormat: pixelFormat, layers: PanoramaLayers(below: panorama), uniforms: u, filtering: filtering)
    }

    /// Rendu hors écran en RGBA16F, relu sur le CPU (tests, export d'aperçu).
    public func renderOffscreen(layers: PanoramaLayers, width: Int, height: Int,
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
        try encode(into: encoder, pixelFormat: .rgba16Float, layers: layers, uniforms: uniforms, filtering: filtering)
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

    public func renderOffscreen(panorama: any MTLTexture, width: Int, height: Int,
                                uniforms: ViewUniforms, filtering: Filtering = .linear) throws -> [Float16] {
        var u = uniforms
        u.layer = .zero
        return try renderOffscreen(layers: PanoramaLayers(below: panorama), width: width, height: height, uniforms: u, filtering: filtering)
    }
}
