import Metal
import PRCore
import PRStorage

/// Un calque et sa texture GPU, avec le cycle de vie d'un trait :
/// - pendant le trait, les dabs sont peints sur le GPU à l'image suivante (latence d'une image) ;
/// - à la fin, les tuiles touchées sont relues dans le calque CPU et forment une entrée d'historique ;
/// - un trait annulé (second doigt posé, pipette) est effacé en recopiant ces tuiles depuis le calque CPU.
/// Sans GPU, ou si la texture n'est pas à pleine résolution, le pinceau CPU de référence prend le relais.
public final class LayerCanvas {
    public let layer: TiledLayer
    public let display: DisplayTexture?
    public var blendSpace: BlendSpace = .perceptual

    private let brush: BrushEngine?
    private let queue: (any MTLCommandQueue)?
    private var pending: [SphericalDab] = []
    private var strokeTiles = Set<TileCoord>()
    /// Tuiles du calque CPU à renvoyer au GPU (pinceau CPU, annulation, chargement).
    private var dirtyTiles = Set<TileCoord>()
    private var needsFullUpload = true
    private var stroking = false
    private var lastCommands: (any MTLCommandBuffer)?

    public init(layer: TiledLayer, device: (any MTLDevice)?, maxDisplayWidth: Int = 8192) {
        self.layer = layer
        display = device.flatMap { try? DisplayTexture(device: $0, layerWidth: layer.width, maxWidth: maxDisplayWidth) }
        let gpuPainting = display?.isFullResolution == true && layer.format == .rgba16Float
        brush = gpuPainting ? device.flatMap { try? BrushEngine(device: $0) } : nil
        queue = device?.makeCommandQueue()
    }

    /// Vrai si le pinceau tourne sur le GPU.
    public var paintsOnGPU: Bool { brush != nil }
    public var isStroking: Bool { stroking }

    // MARK: - Trait

    public func beginStroke() {
        cancelStroke()
        stroking = true
        strokeTiles = []
        if !paintsOnGPU { layer.beginOperation() }
    }

    public func add(_ dabs: [SphericalDab]) {
        guard stroking, !dabs.isEmpty else { return }
        if paintsOnGPU {
            pending.append(contentsOf: dabs)
        } else {
            for dab in dabs { dirtyTiles.formUnion(layer.stamp(dab, space: blendSpace)) }
        }
    }

    /// Termine le trait et renvoie ses deltas (vide si rien n'a changé).
    public func endStroke() -> [TileDelta] {
        guard stroking else { return [] }
        stroking = false
        guard paintsOnGPU, let display, let queue else { return layer.endOperation() }

        // Peint les derniers dabs et attend le GPU avant de relire.
        if let commands = queue.makeCommandBuffer() {
            flushPending(into: commands)
            commands.commit()
            lastCommands = commands
        }
        waitForGPU()
        layer.beginOperation()
        for coord in strokeTiles { layer.replaceTile(coord, with: display.readTile(coord)) }
        strokeTiles = []
        return layer.endOperation()
    }

    /// Abandonne le trait en cours : la toile revient exactement à son état d'avant.
    public func cancelStroke() {
        guard stroking else { return }
        stroking = false
        if paintsOnGPU {
            pending = []
            waitForGPU()
            dirtyTiles.formUnion(strokeTiles)
            strokeTiles = []
        } else {
            for delta in layer.endOperation() {
                layer.restore(delta.before, at: delta.coord)
                dirtyTiles.insert(delta.coord)
            }
        }
    }

    // MARK: - Synchronisation CPU → GPU

    /// Tuiles du calque CPU modifiées hors pinceau (annuler, rétablir…) à renvoyer au GPU.
    public func invalidate(_ tiles: some Sequence<TileCoord>) {
        dirtyTiles.formUnion(tiles)
    }

    public func invalidateAll() {
        needsFullUpload = true
    }

    /// À appeler une fois par image, avant de dessiner : envoie les dabs en attente et les tuiles modifiées.
    public func encodeFrame(into commands: any MTLCommandBuffer) {
        guard let display else { return }
        if needsFullUpload {
            display.uploadAll(layer)
            needsFullUpload = false
            dirtyTiles.removeAll()
        } else if !dirtyTiles.isEmpty {
            display.upload(layer, tiles: dirtyTiles)
            dirtyTiles.removeAll()
        }
        flushPending(into: commands)
        display.finishUpdates(commands)
        lastCommands = commands
    }

    private func flushPending(into commands: any MTLCommandBuffer) {
        guard let brush, let display, !pending.isEmpty else { return }
        strokeTiles.formUnion(brush.encode(pending, space: blendSpace, into: display.texture, commandBuffer: commands))
        pending = []
        display.markChanged()
    }

    private func waitForGPU() {
        guard let commands = lastCommands else { return }
        if commands.status != .notEnqueued { commands.waitUntilCompleted() }
    }
}
