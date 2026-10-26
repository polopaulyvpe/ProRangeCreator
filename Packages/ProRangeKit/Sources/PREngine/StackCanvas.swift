import Metal
import PRCore
import PRStorage

/// La pile de calques côté GPU, avec le cycle de vie d'un trait.
///
/// **Chemin rapide (GPU)** : quand c'est exact, on garde trois textures :
/// - *dessous* : papier + éléments racine sous le calque actif, composés sur le CPU ;
/// - *actif* : le calque actif seul, que le pinceau GPU peint directement ;
/// - *dessus* : éléments racine au-dessus, composés sur transparent.
/// Le shader d'affichage fait `dessus ⊕ (actif ⊕mode dessous)`. C'est exact si le calque actif est à la racine, sans masque
/// ni écrêtage, et si tout ce qui est visible au-dessus est en mode Normal (le Normal est associatif), sans écrêtage sur le calque actif.
///
/// **Chemin CPU** sinon (masque, écrêtage, groupe, mode non Normal au-dessus, peinture du masque, toile > 8K) :
/// le pinceau peint le calque CPU et les tuiles touchées sont recomposées entièrement sur le CPU dans la texture *dessous*.
public final class StackCanvas {
    public private(set) var stack: LayerStack
    public var activeID: UUID {
        didSet { setNeedsRefresh() }
    }
    /// Le pinceau peint le masque du calque actif au lieu de ses pixels.
    public var paintingMask = false {
        didSet { setNeedsRefresh() }
    }
    public var blendSpace: BlendSpace = .perceptual {
        didSet { setNeedsRefresh() }
    }
    public var paper: SIMD3<Float> = [1, 1, 1]
    /// Outils qui lisent les pixels pendant le trait (doigt, clonage) : chemin CPU imposé.
    public var forceCPU = false {
        didSet { if forceCPU != oldValue { setNeedsRefresh() } }
    }
    /// Sélection active : la peinture et les outils y sont limités (chemin CPU), et l'affichage assombrit le reste.
    public var selection: SelectionMask? {
        didSet {
            setNeedsRefresh()
            selectionChanged()
        }
    }
    /// Texture de la sélection pour l'affichage, et contenu flottant pendant une transformation.
    public let selectionTexture: DisplayTexture?
    public let floatingTexture: DisplayTexture?
    public private(set) var hasFloating = false

    public let below: DisplayTexture?
    public let active: DisplayTexture?
    public let above: DisplayTexture?
    public private(set) var usesFastPath = false
    private var aboveIsEmpty = true

    private let brush: BrushEngine?
    private let queue: (any MTLCommandQueue)?
    private var needsRefresh = true
    private var pending: [SphericalDab] = []
    private var strokeTiles = Set<TileCoord>()
    /// Tuiles du calque actif à renvoyer au GPU (chemin rapide).
    private var activeDirty = Set<TileCoord>()
    /// Tuiles à recomposer sur le CPU (dessous et dessus en chemin rapide, tout en chemin CPU).
    private var compositeDirty = Set<TileCoord>()
    private var stroking = false
    private var strokeLayer: TiledLayer?
    private var lastCommands: (any MTLCommandBuffer)?

    public init(stack: LayerStack, device: (any MTLDevice)?, maxDisplayWidth: Int = 8192) {
        self.stack = stack
        activeID = stack.items.last { !$0.isGroup }!.id
        func texture() -> DisplayTexture? {
            device.flatMap { try? DisplayTexture(device: $0, layerWidth: stack.width, maxWidth: maxDisplayWidth) }
        }
        let belowTexture = texture()
        below = belowTexture
        active = texture()
        above = texture()
        // Sélection et contenu flottant : l'affichage suffit, une résolution réduite convient.
        func preview() -> DisplayTexture? {
            device.flatMap { try? DisplayTexture(device: $0, layerWidth: stack.width, maxWidth: min(maxDisplayWidth, 4096)) }
        }
        selectionTexture = preview()
        floatingTexture = preview()
        let fullResolution = belowTexture?.isFullResolution == true && stack.format == .rgba16Float
        brush = fullResolution ? device.flatMap { try? BrushEngine(device: $0) } : nil
        queue = device?.makeCommandQueue()
    }

    public var isStroking: Bool { stroking }

    public func replaceStack(_ newStack: LayerStack) {
        cancelStroke()
        stack = newStack
        activeID = newStack.items.last { !$0.isGroup }!.id
        paintingMask = false
    }

    /// La structure ou des propriétés ont changé : caches à reconstruire à la prochaine image.
    public func setNeedsRefresh() {
        needsRefresh = true
    }

    /// Des pixels d'un calque (ou masque) ont changé hors pinceau (annuler, rétablir…).
    public func invalidate(_ tiles: some Sequence<TileCoord>, layerID: UUID) {
        if usesFastPath, layerID == stack.item(activeID)?.layer?.id {
            activeDirty.formUnion(tiles)
        } else {
            compositeDirty.formUnion(tiles)
        }
    }

    // MARK: - Trait

    private var paintTarget: TiledLayer? {
        guard let item = stack.item(activeID) else { return nil }
        return paintingMask ? item.mask : item.layer
    }

    public func beginStroke() {
        cancelStroke()
        if needsRefresh { refresh() }
        guard let target = paintTarget else { return }
        stroking = true
        strokeLayer = target
        strokeTiles = []
        if !usesFastPath { target.beginOperation() }
    }

    public func add(_ dabs: [SphericalDab]) {
        guard stroking, let target = strokeLayer, !dabs.isEmpty else { return }
        if usesFastPath {
            pending.append(contentsOf: dabs)
        } else {
            let lock = !paintingMask && stack.item(activeID)?.alphaLock == true
            let limit: ((TileCoord) -> [Float]?)? = selection.map { mask in { mask.tileValues($0) } }
            for dab in dabs { compositeDirty.formUnion(target.stamp(dab, space: blendSpace, alphaLock: lock, selection: limit)) }
        }
    }

    /// Modification libre du calque cible pendant un trait sur le chemin CPU (doigt, clonage) : `body` renvoie les tuiles touchées.
    /// Avec une sélection, le résultat y est limité.
    public func edit(_ body: (TiledLayer) -> Set<TileCoord>) {
        guard stroking, !usesFastPath, let target = strokeLayer else { return }
        let tiles = body(target)
        if let selection { target.constrainCurrentOperation(to: selection, tiles: tiles) }
        compositeDirty.formUnion(tiles)
    }

    /// La sélection a changé (tracé, annulation…) : on la renvoie à l'affichage.
    public func selectionChanged() {
        selection?.invalidateCache()
        guard let selectionTexture else { return }
        if let selection { selectionTexture.uploadAll(selection.layer) }
    }

    // MARK: - Ajustements et filtres

    /// Copie GPU du calque cible au début de l'aperçu d'un filtre (source de chaque aperçu).
    private var filterOriginal: (any MTLTexture)?
    private var filterResult: (any MTLTexture)?
    private var filterEngineStorage: FilterEngine?

    public var filterEngine: FilterEngine? {
        if filterEngineStorage == nil, let device = queue?.device { filterEngineStorage = try? FilterEngine(device: device) }
        return filterEngineStorage
    }

    /// Vrai si l'aperçu s'affiche en direct (chemin GPU : on écrit dans la texture du calque actif).
    public var filterPreviewIsLive: Bool { filterOriginal != nil && usesFastPath }

    /// Prépare l'aperçu d'un filtre sur le calque cible.
    public func beginFilter() {
        cancelStroke()
        if needsRefresh { refresh() }
        guard let engine = filterEngine, let target = paintTarget, target.format == .rgba16Float else { return }
        filterOriginal = try? engine.upload(target)
        filterResult = usesFastPath ? active?.texture : (try? engine.makeTexture(width: target.width, height: target.height))
    }

    /// Calcule le filtre ; en chemin GPU, le résultat s'affiche aussitôt.
    public func previewFilter(_ operation: FilterOperation) {
        guard let engine = filterEngine, let original = filterOriginal, let result = filterResult else { return }
        try? engine.run(operation, source: original, destination: result)
        if usesFastPath { active?.markChanged() }
    }

    /// Termine : applique le dernier aperçu au calque (deltas enregistrés, limités à la sélection) ou l'abandonne.
    public func endFilter(apply: Bool) -> (layerID: UUID, deltas: [TileDelta])? {
        defer {
            filterOriginal = nil
            filterResult = nil
        }
        guard let engine = filterEngine, let result = filterResult, let target = paintTarget else { return nil }
        guard apply else {
            if usesFastPath, let layer = stack.item(activeID)?.layer { activeDirty.formUnion(layer.allTileCoords) }
            return nil
        }
        let deltas = engine.readBack(result, into: target, selection: selection)
        if usesFastPath {
            // Avec une sélection, la texture montre le filtre partout : on la recale sur le calque.
            if let layer = stack.item(activeID)?.layer { activeDirty.formUnion(layer.allTileCoords) }
        } else {
            compositeDirty.formUnion(deltas.map(\.coord))
        }
        return (target.id, deltas)
    }

    /// Résultat du dernier aperçu, relu dans un calque à part (pour peindre l'effet au pinceau).
    public func filterResultLayer() -> TiledLayer? {
        guard let engine = filterEngine, let result = filterResult, let target = paintTarget else { return nil }
        let copy = TiledLayer(name: "Effet", width: target.width, height: target.height, format: .rgba16Float)
        _ = engine.readBack(result, into: copy, selection: nil)
        return copy
    }

    /// Contenu à montrer pendant une transformation (le calque actif limité à la sélection), ou nil pour arrêter.
    public func setFloating(_ layer: TiledLayer?) {
        guard let floatingTexture else { return }
        hasFloating = layer != nil
        if let layer { floatingTexture.uploadAll(layer) }
    }

    /// Termine le trait : renvoie le calque modifié et ses deltas (vides si rien n'a changé).
    public func endStroke() -> (layerID: UUID, deltas: [TileDelta])? {
        guard stroking, let target = strokeLayer else { return nil }
        stroking = false
        strokeLayer = nil
        guard usesFastPath, let active, let queue else { return (target.id, target.endOperation()) }

        if let commands = queue.makeCommandBuffer() {
            flushPending(into: commands)
            commands.commit()
            lastCommands = commands
        }
        waitForGPU()
        target.beginOperation()
        for coord in strokeTiles { target.replaceTile(coord, with: active.readTile(coord)) }
        strokeTiles = []
        return (target.id, target.endOperation())
    }

    /// Abandonne le trait en cours : la toile revient exactement à son état d'avant.
    public func cancelStroke() {
        guard stroking, let target = strokeLayer else { return }
        stroking = false
        strokeLayer = nil
        if usesFastPath {
            pending = []
            waitForGPU()
            activeDirty.formUnion(strokeTiles)
            strokeTiles = []
        } else {
            for delta in target.endOperation() {
                target.restore(delta.before, at: delta.coord)
                compositeDirty.insert(delta.coord)
            }
        }
    }

    // MARK: - Image

    /// À appeler une fois par image : met les caches à jour, peint les dabs en attente, régénère les mipmaps.
    public func encodeFrame(into commands: any MTLCommandBuffer) {
        if needsRefresh, !stroking { refresh() }
        if let active, !activeDirty.isEmpty, let layer = stack.item(activeID)?.layer {
            active.upload(layer, tiles: activeDirty)
            activeDirty.removeAll()
        }
        if !compositeDirty.isEmpty {
            recomposite(compositeDirty)
            compositeDirty.removeAll()
        }
        flushPending(into: commands)
        below?.finishUpdates(commands)
        if usesFastPath {
            active?.finishUpdates(commands)
            above?.finishUpdates(commands)
        }
        if selection != nil { selectionTexture?.finishUpdates(commands) }
        if hasFloating { floatingTexture?.finishUpdates(commands) }
        lastCommands = commands
    }

    /// Textures et uniformes de composition pour le renderer.
    public func panoramaLayers() -> PanoramaLayers? {
        guard let below else { return nil }
        var layers = usesFastPath
            ? PanoramaLayers(below: below.texture, active: active?.texture, above: aboveIsEmpty ? nil : above?.texture)
            : PanoramaLayers(below: below.texture)
        if selection != nil { layers.selection = selectionTexture?.texture }
        if hasFloating { layers.floating = floatingTexture?.texture }
        return layers
    }

    public func configure(_ uniforms: inout ViewUniforms) {
        guard usesFastPath, let item = stack.item(activeID) else {
            uniforms.setLayers(activeOpacity: 0, mode: .normal, aboveEnabled: false, space: blendSpace)
            return
        }
        uniforms.setLayers(activeOpacity: item.isVisible ? item.opacity : 0, mode: item.blendMode,
                           aboveEnabled: !aboveIsEmpty, space: blendSpace)
    }

    // MARK: - Caches

    private var rootIndexOfActive: Int? {
        stack.children(of: nil).firstIndex { $0.id == activeID }
    }

    private func fastPathPossible() -> Bool {
        guard brush != nil, !forceCPU, selection == nil, !paintingMask, let item = stack.item(activeID), let layer = item.layer,
              layer.format == .rgba16Float, item.parent == nil, !item.isClipped, item.mask == nil,
              let index = rootIndexOfActive else { return false }
        let aboveItems = stack.children(of: nil).dropFirst(index + 1)
        if let first = aboveItems.first, first.isClipped { return false }
        return aboveItems.allSatisfy { !$0.isVisible || $0.blendMode == .normal }
    }

    private var allTiles: [TileCoord] {
        let (across, down) = TileCoord.gridSize(at: 0, baseWidth: stack.width)
        return (0..<down).flatMap { ty in (0..<across).map { TileCoord(x: $0, y: ty) } }
    }

    private func refresh() {
        needsRefresh = false
        activeDirty.removeAll()
        compositeDirty.removeAll()
        usesFastPath = fastPathPossible()
        if usesFastPath, let layer = stack.item(activeID)?.layer {
            active?.uploadAll(layer)
            let index = rootIndexOfActive!
            aboveIsEmpty = !stack.children(of: nil).dropFirst(index + 1).contains { $0.isVisible }
        }
        recomposite(Set(allTiles))
    }

    private func recomposite(_ tiles: Set<TileCoord>) {
        let occupied = LayerCompositor.occupiedTiles(stack)
        let paperPixel = SIMD4<Float>(paper.x, paper.y, paper.z, 1)
        let roots = stack.children(of: nil)
        for coord in tiles {
            if !occupied.contains(coord) {
                // Rien de peint ici : papier dessous, rien dessus.
                below?.fill(coord, with: paperPixel)
                if usesFastPath { above?.fill(coord, with: .zero) }
                continue
            }
            if usesFastPath, let index = rootIndexOfActive {
                below?.upload(coord, pixels: LayerCompositor.compositeTile(coord, stack: stack, rootRange: 0..<index,
                                                                           paper: paper, space: blendSpace))
                if !aboveIsEmpty {
                    above?.upload(coord, pixels: LayerCompositor.compositeTile(coord, stack: stack, rootRange: (index + 1)..<roots.count,
                                                                               paper: nil, space: blendSpace))
                }
            } else {
                below?.upload(coord, pixels: LayerCompositor.compositeTile(coord, stack: stack, paper: paper, space: blendSpace))
            }
        }
    }

    private func flushPending(into commands: any MTLCommandBuffer) {
        guard let brush, let active, !pending.isEmpty else { return }
        let lock = stack.item(activeID)?.alphaLock == true
        strokeTiles.formUnion(brush.encode(pending, space: blendSpace, alphaLock: lock, into: active.texture, commandBuffer: commands))
        pending = []
        active.markChanged()
    }

    private func waitForGPU() {
        guard let commands = lastCommands else { return }
        if commands.status != .notEnqueued { commands.waitUntilCompleted() }
    }
}
