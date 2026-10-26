import MetalKit
import PRCore
import PREngine
import PRStorage
import simd
import SwiftUI
import UIKit

enum PaintTool: String, CaseIterable {
    case brush
    case eraser
    case smudge
    case clone
    case fill
    case gradient
    case select
    case liquify
    case effect

    var label: String {
        switch self {
        case .brush: "Pinceau"
        case .eraser: "Gomme"
        case .smudge: "Doigt"
        case .clone: "Clonage"
        case .fill: "Remplissage"
        case .gradient: "Dégradé"
        case .select: "Sélection"
        case .liquify: "Liquify"
        case .effect: "Pinceau d'effet"
        }
    }

    var symbol: String {
        switch self {
        case .brush: "paintbrush.pointed"
        case .eraser: "eraser"
        case .smudge: "hand.point.up.left"
        case .clone: "square.on.square.dashed"
        case .fill: "drop"
        case .gradient: "circle.lefthalf.striped.horizontal"
        case .select: "lasso"
        case .liquify: "tornado"
        case .effect: "wand.and.rays"
        }
    }

    /// Outils qui lisent les pixels pendant le trait : chemin CPU.
    var needsCPU: Bool { self == .smudge || self == .clone || self == .liquify || self == .effect }
}

/// État de l'écran Toile : un calque, l'historique, la vue, les outils et l'affichage.
@MainActor
@Observable
final class CanvasSession {
    static let canvasWidth = 8192
    static let morphDuration = 0.6
    static let maxRecentColors = 10

    /// La pile est une classe : `layersVersion` signale ses changements à SwiftUI.
    @ObservationIgnored private(set) var stack = LayerStack(width: CanvasSession.canvasWidth, height: CanvasSession.canvasWidth / 2)
    private(set) var history = UndoRedoManager()
    var layersVersion = 0
    var activeID = UUID()
    private(set) var paintingMask = false
    /// Calques garantis par la mémoire disponible au dernier contrôle (voir `MemoryBudget`).
    private(set) var guaranteedLayers = LayerStack.maxLayers
    var showLayers = false
    @ObservationIgnored var structureBeforeEdit: [StackItem]?

    /// Créé par le coordinateur Metal (il faut le GPU).
    @ObservationIgnored var canvas: StackCanvas?
    @ObservationIgnored var device: (any MTLDevice)?

    // Fichier (voir ProjectFiles.swift)
    var projectName = "Sans titre"
    var projectCreatedAt = Date()
    var showProjects = false
    var showExport = false
    var fileMessage: String?
    var isExporting = false
    var exportProgress = 0.0
    var lastExportURL: URL?
    @ObservationIgnored var exportCancel: CancelFlag?
    /// Lu à chaque image et modifié par les gestes : hors observation pour ne pas redessiner SwiftUI en continu.
    @ObservationIgnored var view = ViewState()

    private(set) var mode: ViewMode = .sphere
    private(set) var horizonLocked = true
    private(set) var fovDegrees = 90.0
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var recentColors: [SIMD3<Double>] = []
    private(set) var blendSpace: BlendSpace = .perceptual
    var tool: PaintTool = .brush
    var brush = BrushSettings.defaultBrush
    var eraser = BrushSettings.defaultEraser
    /// Couleur courante, composantes encodées sRGB dans [0, 1].
    var color: SIMD3<Double> = [0.15, 0.35, 0.85]
    var toneMapping: ToneMapping = .clip
    var exposure = 0.0
    var showColorPicker = false

    // Outils sphériques (voir SphereToolsUI.swift)
    var symmetry = SymmetrySettings()
    var guidesEnabled = false
    var guideSpacing = 15.0
    var gradientShape: SphericalGradient.Shape = .linear
    var fillThreshold = 0.1
    var smudgeStrength = 0.6
    var cloneSource: Vec3?
    var showRotation = false
    /// Aperçu de rotation de la sphère, en degrés (lacet, tangage, roulis).
    var sphereRotation: SIMD3<Double> = .zero
    @ObservationIgnored var warp: WarpEngine?
    @ObservationIgnored var cloneSampler: LayerSampler?
    @ObservationIgnored var cloneRotation = matrix_identity_double3x3
    @ObservationIgnored var gradientStart: Vec3?
    @ObservationIgnored var lastDirection: Vec3?
    @ObservationIgnored var smudgePrevious: [Vec3] = []
    @ObservationIgnored var lastAspect = 1.5

    // Sélection et transformation (voir SelectionUI.swift)
    @ObservationIgnored var selection: SelectionMask?
    var hasSelection = false
    var selectionKind: SelectionKind = .rectangle
    var selectionCombine: SelectionCombine = .replace
    var selectionThreshold = 0.1
    /// Tracé en cours, en NDC (affiché par-dessus la toile).
    var selectionDrag: [SIMD2<Double>] = []
    var transform: SphericalTransform?

    // Lot C (voir DeformationUI.swift)
    var liquifyMode: LiquifyMode = .push
    var liquifyStrength = 0.6
    var quickShapeEnabled = true
    var distort: SphericalDistort?
    var showTextSheet = false

    // Phase 6 (voir AdjustmentsUI.swift)
    var activeFilter: FilterKind?
    var filterSettings = FilterSettings()
    var filterPreviewIsLive = false
    @ObservationIgnored var activeCorner: Int?
    @ObservationIgnored var quickShapePoints: [Vec3] = []
    @ObservationIgnored var quickShapePressure = 1.0
    @ObservationIgnored var quickShapeLastMove: CFTimeInterval = 0
    @ObservationIgnored var quickShapeTimer: Timer?
    @ObservationIgnored var quickShapeApplied = false

    @ObservationIgnored private var sampler = SphericalStrokeSampler()
    @ObservationIgnored private var morphAnimation: (from: Double, to: Double, start: CFTimeInterval)?

    var settings: BrushSettings {
        get { tool == .brush ? brush : eraser }
        set { if tool == .brush { brush = newValue } else { eraser = newValue } }
    }

    // MARK: - Vues

    func setMode(_ newMode: ViewMode) {
        switch newMode {
        case .unfolded:
            guard mode != .unfolded else { return }
            if mode == .flat { view.morph = 0 }
            view.prepareUnfold()
            view.mode = .unfolded
            animateMorph(to: 1)
        case .sphere:
            if mode == .unfolded {
                view.prepareFold()
                view.mode = .sphere
                animateMorph(to: 0)
            } else {
                view.mode = .sphere
                view.morph = 0
            }
        case .flat:
            morphAnimation = nil
            view.morph = 0
            view.showFace(view.face)
        }
        mode = newMode
        refreshViewInfo()
    }

    func toggleUnfold() {
        setMode(mode == .unfolded ? .sphere : .unfolded)
    }

    func showFace(_ face: CubeFace) {
        morphAnimation = nil
        view.morph = 0
        view.showFace(face)
        mode = .flat
        refreshViewInfo()
    }

    func setHorizonLocked(_ locked: Bool) {
        view.horizonLocked = locked
        if locked { view.roll = 0 }
        horizonLocked = locked
    }

    func setBlendSpace(_ space: BlendSpace) {
        blendSpace = space
        canvas?.blendSpace = space
    }

    /// Avance l'animation de dépliage (appelé à chaque image).
    func advance(now: CFTimeInterval) {
        guard let anim = morphAnimation else { return }
        let t = min(1, (now - anim.start) / Self.morphDuration)
        let eased = t * t * (3 - 2 * t)
        view.morph = anim.from + (anim.to - anim.from) * eased
        if t >= 1 { morphAnimation = nil }
    }

    private func animateMorph(to target: Double) {
        morphAnimation = (view.morph, target, CACurrentMediaTime())
    }

    func refreshViewInfo() {
        fovDegrees = (mode == .flat ? view.flatFov : view.fov) * 180 / .pi
    }

    // MARK: - Peinture

    func dab(at center: Vec3, pressure: Double) -> SphericalDab {
        let linear = ColorTransfer.toLinear(SIMD3<Float>(Float(color.x), Float(color.y), Float(color.z)))
        return settings.dab(at: center, pressure: pressure, color: linear, mode: tool == .brush ? .paint : .erase)
    }

    func strokeBegan(ndc: SIMD2<Double>, aspect: Double, pressure: Double) {
        lastAspect = aspect
        guard let canvas, let d = view.direction(atNDC: ndc, aspect: aspect) else { return }
        lastDirection = d
        if distort != nil {
            grabDistortCorner(ndc: ndc)
            return
        }
        if transform != nil {
            moveTransform(to: d)
            return
        }
        if tool == .select {
            selectionBegan(ndc: ndc, direction: d)
            return
        }
        switch tool {
        case .fill:
            fill(at: d)
            return
        case .gradient:
            gradientStart = d
            return
        case .clone where cloneSource == nil:
            cloneSource = d
            fileMessage = "Source du clonage définie : peins ailleurs pour la recopier"
            return
        default:
            break
        }
        canvas.forceCPU = tool.needsCPU
        canvas.beginStroke()
        if tool == .brush { rememberColor() }
        let centers = sampler.begin(at: d)
        switch tool {
        case .smudge, .liquify:
            smudgePrevious = symmetry.images(of: d)
        case .effect:
            applyClone(centers, pressure: pressure)
        case .clone:
            beginClone(at: d)
            applyClone(centers, pressure: pressure)
        default:
            canvas.add(symmetricDabs(centers, pressure: pressure))
            beginQuickShapeWatch(at: d, pressure: pressure)
        }
    }

    func strokeMoved(ndc: SIMD2<Double>, aspect: Double, pressure: Double) {
        lastAspect = aspect
        if tool == .select, transform == nil {
            selectionMoved(ndc: ndc)
            return
        }
        guard let d = view.direction(atNDC: ndc, aspect: aspect) else { return }
        lastDirection = d
        if distort != nil {
            moveDistortCorner(to: d)
            return
        }
        if transform != nil {
            moveTransform(to: d)
            return
        }
        guard let canvas, canvas.isStroking, !quickShapeApplied else { return }
        let spacing = max(settings.radius(pressure: pressure) * settings.spacing, 1e-4)
        let centers = sampler.add(d, spacing: spacing)
        switch tool {
        case .smudge: applySmudge(centers, pressure: pressure)
        case .liquify: applyLiquify(centers, pressure: pressure)
        case .clone, .effect: applyClone(centers, pressure: pressure)
        default:
            canvas.add(symmetricDabs(centers, pressure: pressure))
            noteQuickShapePoint(d)
        }
    }

    /// Dabs du trait et leurs copies par symétrie.
    func symmetricDabs(_ centers: [Vec3], pressure: Double) -> [SphericalDab] {
        centers.flatMap { symmetry.images(of: $0) }.map { dab(at: $0, pressure: pressure) }
    }

    func strokeEnded() {
        stopQuickShapeWatch()
        if distort != nil {
            activeCorner = nil
            return
        }
        if transform != nil { return }
        if tool == .select {
            selectionEnded()
            return
        }
        if tool == .gradient, let start = gradientStart, let end = lastDirection {
            gradientStart = nil
            applyGradient(from: start, to: end)
            return
        }
        guard let canvas, canvas.isStroking else { return }
        if let result = canvas.endStroke(), !result.deltas.isEmpty {
            history.record(HistoryEntry(name: tool == .brush ? "Trait" : "Gomme", layerID: result.layerID, deltas: result.deltas))
        }
        refreshHistory()
    }

    /// Second doigt posé ou pipette : le trait commencé disparaît sans laisser de trace.
    func strokeCancelled() {
        canvas?.cancelStroke()
    }

    // MARK: - Historique

    func undo() {
        strokeCancelled()
        cancelTransform()
        cancelDistort()
        if let entry = try? history.undo(in: historyTarget) { invalidate(entry) }
        refreshHistory()
    }

    func redo() {
        strokeCancelled()
        cancelTransform()
        cancelDistort()
        if let entry = try? history.redo(in: historyTarget) { invalidate(entry) }
        refreshHistory()
    }

    /// La pile et la sélection : tout ce que l'historique peut restaurer.
    private var historyTarget: HistoryTarget { SessionHistoryTarget(stack: stack, selection: selection) }

    private func invalidate(_ entry: HistoryEntry) {
        let changes = entry.allChanges
        if let selection, changes.contains(where: { $0.layerID == selection.layer.id }) { selectionUpdated() }
        if entry.structure != nil || entry.isSpilled || changes.count > 1 {
            structureChanged()
        } else if entry.layerID != selection?.layer.id {
            canvas?.invalidate(entry.deltas.map(\.coord), layerID: entry.layerID)
        }
    }

    /// Remplace la pile (nouveau projet, ouverture) : caches GPU reconstruits, historique vidé.
    func replaceStack(_ newStack: LayerStack) {
        strokeCancelled()
        stack = newStack
        history = UndoRedoManager()
        if let canvas {
            canvas.replaceStack(newStack)
        } else {
            canvas = StackCanvas(stack: newStack, device: device)
        }
        canvas?.blendSpace = blendSpace
        activeID = canvas?.activeID ?? newStack.items.last { !$0.isGroup }!.id
        paintingMask = false
        refreshHistory()
        structureChanged()
    }

    /// Après tout changement de structure ou de propriété : calque actif valide, caches à refaire, interface à jour.
    func structureChanged() {
        if stack.item(activeID) == nil {
            activeID = stack.items.last { !$0.isGroup }?.id ?? stack.items.last!.id
        }
        if stack.item(activeID)?.mask == nil { paintingMask = false }
        canvas?.activeID = activeID
        canvas?.paintingMask = paintingMask
        canvas?.setNeedsRefresh()
        if let available = MemoryBudgetManager.systemAvailableBytes() {
            guaranteedLayers = stack.guaranteedLayers(availableBytes: available)
        }
        layersVersion += 1
    }

    func selectLayer(_ id: UUID) {
        strokeCancelled()
        activeID = id
        paintingMask = false
        structureChanged()
    }

    func setPaintingMask(_ value: Bool) {
        strokeCancelled()
        paintingMask = value && stack.item(activeID)?.mask != nil
        structureChanged()
    }

    func refreshHistory() {
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    // MARK: - Couleur

    /// Pipette : couleur affichée sous le doigt (toute la pile composée sur le papier blanc).
    func pickColor(ndc: SIMD2<Double>, aspect: Double) {
        guard let d = view.direction(atNDC: ndc, aspect: aspect) else { return }
        let p = Equirect.pixel(from: d, width: stack.width, height: stack.height)
        let x = min(stack.width - 1, max(0, Int(p.x)))
        let y = min(stack.height - 1, max(0, Int(p.y)))
        let coord = TileCoord.containing(x: x, y: y)
        let tile = LayerCompositor.compositeTile(coord, stack: stack, paper: [1, 1, 1], space: blendSpace)
        let px = tile[(y % TileSize.side) * TileSize.side + x % TileSize.side]
        let encoded = ColorTransfer.toEncoded(SIMD3<Float>(px.x, px.y, px.z))
        color = [Double(min(1, max(0, encoded.x))), Double(min(1, max(0, encoded.y))), Double(min(1, max(0, encoded.z)))]
        tool = .brush
    }

    func rememberColor() {
        recentColors.removeAll { simd_length($0 - color) < 1e-4 }
        recentColors.insert(color, at: 0)
        if recentColors.count > Self.maxRecentColors { recentColors.removeLast() }
    }
}

// MARK: - Vue Metal

/// Reçoit les touches : un doigt ou le Pencil peint ; un second doigt annule le trait commencé.
final class CanvasMTKView: MTKView {
    weak var coordinator: CanvasCoordinator?

    private var aspect: Double { Double(bounds.width / max(bounds.height, 1)) }

    func ndc(_ p: CGPoint) -> SIMD2<Double> {
        [Double(p.x / bounds.width) * 2 - 1, 1 - Double(p.y / bounds.height) * 2]
    }

    /// Pression normalisée du Pencil ; le doigt n'en a pas (1).
    private func pressure(_ touch: UITouch) -> Double {
        guard touch.type == .pencil, touch.maximumPossibleForce > 0 else { return 1 }
        return Double(touch.force / touch.maximumPossibleForce)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let session = coordinator?.session else { return }
        guard let touch = touches.first, (event?.allTouches?.count ?? 1) == 1 else {
            session.strokeCancelled()
            return
        }
        session.strokeBegan(ndc: ndc(touch.location(in: self)), aspect: aspect, pressure: pressure(touch))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let session = coordinator?.session, let touch = touches.first else { return }
        if (event?.allTouches?.count ?? 1) > 1 {
            session.strokeCancelled()
            return
        }
        for t in event?.coalescedTouches(for: touch) ?? [touch] {
            session.strokeMoved(ndc: ndc(t.location(in: self)), aspect: aspect, pressure: pressure(t))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        coordinator?.session.strokeEnded()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        coordinator?.session.strokeCancelled()
    }
}

@MainActor
final class CanvasCoordinator: NSObject, UIGestureRecognizerDelegate {
    let session: CanvasSession
    let device: (any MTLDevice)?
    private let queue: (any MTLCommandQueue)?
    private let renderer: PanoramaRenderer?
    private var rapidUndoTimer: Timer?

    init(session: CanvasSession) {
        self.session = session
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        queue = device?.makeCommandQueue()
        renderer = device.flatMap { try? PanoramaRenderer(device: $0) }
        session.device = device
        if session.canvas == nil { session.replaceStack(session.stack) }
    }

    func render(in view: MTKView) {
        session.advance(now: CACurrentMediaTime())
        guard let renderer, let queue, let canvas = session.canvas,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer() else { return }
        canvas.encodeFrame(into: commands)
        guard let layers = canvas.panoramaLayers() else { return }

        let size = view.drawableSize
        let parameters = session.view.parameters(aspect: Double(size.width / max(size.height, 1)))
        var uniforms = ViewUniforms(parameters, viewportHeight: Int(size.height), textureHeight: layers.below.height,
                                    exposure: session.exposure, toneMapping: session.toneMapping)
        canvas.configure(&uniforms)
        uniforms.setContentRotation(session.showRotation ? session.previewRotation : nil)
        uniforms.setGuides(enabled: session.guidesEnabled, spacingDegrees: session.guideSpacing)
        if let distort = session.distort {
            uniforms.setSelection(visible: session.hasSelection, distort: distort)
        } else {
            uniforms.setSelection(visible: session.hasSelection, transform: session.transform)
        }
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        try? renderer.encode(into: encoder, pixelFormat: view.colorPixelFormat, layers: layers, uniforms: uniforms)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    // MARK: - Navigation

    @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        session.view.zoom(by: Double(gesture.scale))
        gesture.scale = 1
        session.refreshViewInfo()
    }

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let t = gesture.translation(in: view)
        let size = view.bounds.size
        session.view.pan(byNDC: [Double(t.x / size.width) * 2, -Double(t.y / size.height) * 2],
                         aspect: Double(size.width / size.height))
        gesture.setTranslation(.zero, in: view)
    }

    @objc func handleRotation(_ gesture: UIRotationGestureRecognizer) {
        session.view.rotate(by: Double(gesture.rotation))
        gesture.rotation = 0
    }

    // MARK: - Historique (D6)

    @objc func handleUndoTap(_ gesture: UITapGestureRecognizer) {
        session.undo()
    }

    @objc func handleRedoTap(_ gesture: UITapGestureRecognizer) {
        session.redo()
    }

    /// Maintien à deux doigts : annulation rapide continue.
    @objc func handleUndoHold(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            session.undo()
            rapidUndoTimer?.invalidate()
            rapidUndoTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.session.undo() }
            }
        case .ended, .cancelled, .failed:
            rapidUndoTimer?.invalidate()
            rapidUndoTimer = nil
        default:
            break
        }
    }

    // MARK: - Pipette

    @objc func handleEyedropper(_ gesture: UILongPressGestureRecognizer) {
        guard let view = gesture.view as? CanvasMTKView, gesture.state == .began || gesture.state == .changed else { return }
        session.strokeCancelled()
        session.pickColor(ndc: view.ndc(gesture.location(in: view)), aspect: Double(view.bounds.width / max(view.bounds.height, 1)))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

extension CanvasCoordinator: @preconcurrency MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        render(in: view)
    }
}

struct MetalCanvas: UIViewRepresentable {
    let session: CanvasSession

    func makeCoordinator() -> CanvasCoordinator {
        CanvasCoordinator(session: session)
    }

    func makeUIView(context: Context) -> CanvasMTKView {
        let coordinator = context.coordinator
        let view = CanvasMTKView(frame: .zero, device: coordinator.device)
        view.coordinator = coordinator
        view.delegate = coordinator
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.preferredFramesPerSecond = 120
        view.isMultipleTouchEnabled = true

        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(CanvasCoordinator.handlePinch(_:)))
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(CanvasCoordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        let rotation = UIRotationGestureRecognizer(target: coordinator, action: #selector(CanvasCoordinator.handleRotation(_:)))

        let undoTap = UITapGestureRecognizer(target: coordinator, action: #selector(CanvasCoordinator.handleUndoTap(_:)))
        undoTap.numberOfTouchesRequired = 2
        undoTap.numberOfTapsRequired = 2
        let redoTap = UITapGestureRecognizer(target: coordinator, action: #selector(CanvasCoordinator.handleRedoTap(_:)))
        redoTap.numberOfTouchesRequired = 3
        redoTap.numberOfTapsRequired = 2
        let undoHold = UILongPressGestureRecognizer(target: coordinator, action: #selector(CanvasCoordinator.handleUndoHold(_:)))
        undoHold.numberOfTouchesRequired = 2
        undoHold.minimumPressDuration = 0.6
        let eyedropper = UILongPressGestureRecognizer(target: coordinator, action: #selector(CanvasCoordinator.handleEyedropper(_:)))
        eyedropper.numberOfTouchesRequired = 1
        eyedropper.minimumPressDuration = 0.5

        for gesture in [pinch, pan, rotation, undoTap, redoTap, undoHold, eyedropper] as [UIGestureRecognizer] {
            gesture.delegate = coordinator
            view.addGestureRecognizer(gesture)
        }
        return view
    }

    func updateUIView(_ uiView: CanvasMTKView, context: Context) {}
}

// MARK: - Écran

struct CanvasScreen: View {
    @State private var session = CanvasSession()

    var body: some View {
        ZStack(alignment: .topLeading) {
            MetalCanvas(session: session)
                .ignoresSafeArea()
            SelectionDragOverlay(session: session)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            DistortHandlesOverlay(session: session)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 12) {
                CanvasToolbar(session: session)
                TransformPanel(session: session)
                DistortPanel(session: session)
                FilterPanel(session: session)
                SideControls(session: session)
            }
            .padding(12)
        }
    }
}

/// Colonne de gauche, comme dans Procreate : taille et opacité de l'outil, annuler / rétablir.
struct SideControls: View {
    @Bindable var session: CanvasSession

    var body: some View {
        VStack(spacing: 28) {
            VerticalSlider(value: $session.settings.radiusDegrees, range: 0.3...30, label: "Taille")
            VerticalSlider(value: $session.settings.opacity, range: 0.02...1, label: "Opacité")
            VStack(spacing: 14) {
                Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!session.canUndo)
                Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!session.canRedo)
            }
            .font(.title3)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            GeometryReader { geo in
                let span = range.upperBound - range.lowerBound
                let fraction = (value - range.lowerBound) / span
                ZStack(alignment: .bottom) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.tint).frame(height: max(10, geo.size.height * fraction))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let f = 1 - min(max(drag.location.y / geo.size.height, 0), 1)
                    value = range.lowerBound + f * span
                })
            }
            .frame(width: 26, height: 170)
        }
    }
}

struct CanvasToolbar: View {
    @Bindable var session: CanvasSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                FileMenu(session: session)
                    .fixedSize()
                LayersButton(session: session)

                Picker("Vue", selection: Binding(get: { session.mode }, set: { session.setMode($0) })) {
                    ForEach(ViewMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)

                Button(session.mode == .unfolded ? "Replier" : "Déplier",
                       systemImage: session.mode == .unfolded ? "globe" : "rectangle.expand.vertical") {
                    session.toggleUnfold()
                }
                .buttonStyle(.borderedProminent)

                if session.mode == .flat {
                    Menu("Face", systemImage: "cube") {
                        ForEach(CubeFace.allCases, id: \.self) { face in
                            Button(face.label) { session.showFace(face) }
                        }
                    }
                }
                if session.mode == .sphere {
                    Toggle("Horizon verrouillé", isOn: Binding(get: { session.horizonLocked },
                                                              set: { session.setHorizonLocked($0) }))
                        .fixedSize()
                }
                if session.mode != .unfolded {
                    Text("Champ \(Int(session.fovDegrees))°")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 16) {
                ToolPicker(session: session)
                AdjustmentsMenu(session: session)

                Button {
                    session.showColorPicker = true
                } label: {
                    Circle()
                        .fill(Color(.sRGB, red: session.color.x, green: session.color.y, blue: session.color.z))
                        .frame(width: 30, height: 30)
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2))
                }
                .popover(isPresented: $session.showColorPicker) {
                    ColorPickerPanel(session: session)
                        .padding(18)
                }

                ToolOptions(session: session)
                SphereToolsMenus(session: session)

                Menu("Fusion : \(session.blendSpace.label)") {
                    ForEach(BlendSpace.allCases, id: \.self) { space in
                        Button(space.label) { session.setBlendSpace(space) }
                    }
                }

                Picker("Affichage", selection: $session.toneMapping) {
                    ForEach(ToneMapping.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Exposition \(session.exposure, format: .number.precision(.fractionLength(1))) EV")
                    Slider(value: $session.exposure, in: -4...4)
                }
                .frame(width: 170)
            }
        }
        .font(.callout)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
