import MetalKit
import PRCore
import PREngine
import PRStorage
import SwiftUI
import UIKit

/// État de l'écran Toile : un calque, l'historique, la vue et les réglages d'affichage.
/// Le pinceau est encore le rasteriseur CPU (le pinceau Metal arrive en phase 3).
@MainActor
@Observable
final class CanvasSession {
    static let canvasWidth = 8192
    static let morphDuration = 0.6

    let layer = TiledLayer(name: "Calque 1", width: CanvasSession.canvasWidth, height: CanvasSession.canvasWidth / 2)
    let history = UndoRedoManager()

    /// Lu à chaque image et modifié par les gestes : hors observation pour ne pas redessiner SwiftUI en continu.
    @ObservationIgnored var view = ViewState()
    @ObservationIgnored var dirtyTiles = Set<TileCoord>()
    @ObservationIgnored var needsFullUpload = true

    private(set) var mode: ViewMode = .sphere
    private(set) var horizonLocked = true
    private(set) var fovDegrees = 90.0
    private(set) var canUndo = false
    private(set) var canRedo = false
    var toneMapping: ToneMapping = .clip
    var exposure = 0.0
    var brushRadiusDegrees = 2.0
    var hardness = 0.8
    var colorIndex = 0

    @ObservationIgnored private var sampler = SphericalStrokeSampler()
    @ObservationIgnored private var stroking = false
    @ObservationIgnored private var morphAnimation: (from: Double, to: Double, start: CFTimeInterval)?

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

    private var linearColor: SIMD4<Float> {
        let c = PaletteColor.all[colorIndex].rgb
        return [ColorTransfer.toLinear(c.x), ColorTransfer.toLinear(c.y), ColorTransfer.toLinear(c.z), 1]
    }

    func strokeBegan(ndc: SIMD2<Double>, aspect: Double) {
        guard !stroking, let d = view.direction(atNDC: ndc, aspect: aspect) else { return }
        layer.beginOperation()
        stroking = true
        stamp(sampler.begin(at: d))
    }

    func strokeMoved(ndc: SIMD2<Double>, aspect: Double) {
        guard stroking, let d = view.direction(atNDC: ndc, aspect: aspect) else { return }
        stamp(sampler.add(d, spacing: brushRadiusDegrees * .pi / 180 * 0.15))
    }

    func strokeEnded() {
        guard stroking else { return }
        stroking = false
        let deltas = layer.endOperation()
        if !deltas.isEmpty { history.record(HistoryEntry(name: "Trait", layerID: layer.id, deltas: deltas)) }
        refreshHistory()
    }

    private func stamp(_ centers: [Vec3]) {
        let radius = brushRadiusDegrees * .pi / 180
        for center in centers {
            let dab = SphericalDab(center: center, radius: radius, hardness: hardness, color: linearColor)
            dirtyTiles.formUnion(layer.stamp(dab))
        }
    }

    func undo() {
        if let entry = try? history.undo(in: [layer]) { markDirty(entry) }
        refreshHistory()
    }

    func redo() {
        if let entry = try? history.redo(in: [layer]) { markDirty(entry) }
        refreshHistory()
    }

    private func markDirty(_ entry: HistoryEntry) {
        if entry.isSpilled { needsFullUpload = true } else { dirtyTiles.formUnion(entry.deltas.map(\.coord)) }
    }

    private func refreshHistory() {
        canUndo = history.canUndo
        canRedo = history.canRedo
    }
}

// MARK: - Vue Metal

/// Reçoit les touches : un doigt ou le Pencil peint, deux doigts naviguent (gestionnaires de gestes du coordinateur).
final class CanvasMTKView: MTKView {
    weak var coordinator: CanvasCoordinator?

    private var aspect: Double { Double(bounds.width / max(bounds.height, 1)) }

    private func ndc(_ p: CGPoint) -> SIMD2<Double> {
        [Double(p.x / bounds.width) * 2 - 1, 1 - Double(p.y / bounds.height) * 2]
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let session = coordinator?.session else { return }
        guard let touch = touches.first, (event?.allTouches?.count ?? 1) == 1 else {
            session.strokeEnded()
            return
        }
        session.strokeBegan(ndc: ndc(touch.location(in: self)), aspect: aspect)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let session = coordinator?.session, let touch = touches.first else { return }
        if (event?.allTouches?.count ?? 1) > 1 {
            session.strokeEnded()
            return
        }
        for t in event?.coalescedTouches(for: touch) ?? [touch] {
            session.strokeMoved(ndc: ndc(t.location(in: self)), aspect: aspect)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        coordinator?.session.strokeEnded()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        coordinator?.session.strokeEnded()
    }
}

@MainActor
final class CanvasCoordinator: NSObject, UIGestureRecognizerDelegate {
    let session: CanvasSession
    let device: (any MTLDevice)?
    private let queue: (any MTLCommandQueue)?
    private let renderer: PanoramaRenderer?
    private let display: DisplayTexture?

    init(session: CanvasSession) {
        self.session = session
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        queue = device?.makeCommandQueue()
        renderer = device.flatMap { try? PanoramaRenderer(device: $0) }
        display = device.flatMap { try? DisplayTexture(device: $0, layerWidth: session.layer.width) }
    }

    func render(in view: MTKView) {
        session.advance(now: CACurrentMediaTime())
        guard let renderer, let display, let queue,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer() else { return }

        if session.needsFullUpload {
            display.uploadAll(session.layer)
            session.needsFullUpload = false
            session.dirtyTiles.removeAll()
        } else if !session.dirtyTiles.isEmpty {
            display.upload(session.layer, tiles: session.dirtyTiles)
            session.dirtyTiles.removeAll()
        }
        display.finishUpdates(commands)

        let size = view.drawableSize
        let parameters = session.view.parameters(aspect: Double(size.width / max(size.height, 1)))
        let uniforms = ViewUniforms(parameters, viewportHeight: Int(size.height), textureHeight: display.texture.height,
                                    exposure: session.exposure, toneMapping: session.toneMapping)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        try? renderer.encode(into: encoder, pixelFormat: view.colorPixelFormat, panorama: display.texture, uniforms: uniforms)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

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
        for gesture in [pinch, pan, rotation] as [UIGestureRecognizer] {
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
        ZStack(alignment: .top) {
            MetalCanvas(session: session)
                .ignoresSafeArea()
            CanvasToolbar(session: session)
                .padding(12)
        }
    }
}

struct CanvasToolbar: View {
    @Bindable var session: CanvasSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
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

                Spacer()

                Button("Annuler", systemImage: "arrow.uturn.backward") { session.undo() }
                    .disabled(!session.canUndo)
                Button("Rétablir", systemImage: "arrow.uturn.forward") { session.redo() }
                    .disabled(!session.canRedo)
            }

            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Taille \(session.brushRadiusDegrees, format: .number.precision(.fractionLength(1)))°")
                    Slider(value: $session.brushRadiusDegrees, in: 0.3...30)
                }
                .frame(width: 180)

                Picker("Couleur", selection: $session.colorIndex) {
                    ForEach(PaletteColor.all.indices, id: \.self) { Text(PaletteColor.all[$0].name).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                Spacer()

                Picker("Affichage", selection: $session.toneMapping) {
                    ForEach(ToneMapping.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Exposition \(session.exposure, format: .number.precision(.fractionLength(1))) EV")
                    Slider(value: $session.exposure, in: -4...4)
                }
                .frame(width: 180)
            }
        }
        .font(.callout)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
