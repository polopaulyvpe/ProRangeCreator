import PRCore
import PREngine
import PRStorage
import simd
import SwiftUI

/// Outils sphériques du lot A : remplissage, dégradé, doigt, clonage, symétrie, guides, rotation de la sphère.
extension CanvasSession {
    /// Calque que les outils modifient : les pixels du calque actif, ou son masque.
    var editTarget: TiledLayer? {
        guard let item = stack.item(activeID) else { return nil }
        return paintingMask ? item.mask : item.layer
    }

    private var toolColor: SIMD4<Float> {
        let linear = ColorTransfer.toLinear(SIMD3<Float>(Float(color.x), Float(color.y), Float(color.z)))
        return SIMD4<Float>(linear.x, linear.y, linear.z, Float(brush.opacity))
    }

    /// Exécute une modification ponctuelle du calque cible, l'enregistre et rafraîchit l'affichage.
    private func recordEdit(_ name: String, _ body: (TiledLayer) -> Set<TileCoord>) {
        strokeCancelled()
        guard let target = editTarget else { return }
        target.beginOperation()
        let tiles = body(target)
        let deltas = target.endOperation()
        guard !deltas.isEmpty else { return }
        history.record(HistoryEntry(name: name, layerID: target.id, deltas: deltas))
        canvas?.invalidate(tiles, layerID: target.id)
        refreshHistory()
    }

    func fill(at d: Vec3) {
        rememberColorIfNeeded()
        let color = toolColor
        recordEdit("Remplissage") { $0.floodFill(from: d, color: color, threshold: Float(fillThreshold), space: blendSpace) }
    }

    func applyGradient(from start: Vec3, to end: Vec3) {
        guard Sphere.angle(start, end) > 1e-4 else { return }
        rememberColorIfNeeded()
        let from = toolColor
        let to = SIMD4<Float>(from.x, from.y, from.z, 0)
        let gradient = SphericalGradient(shape: gradientShape, start: start, end: end)
        recordEdit("Dégradé") { $0.applyGradient(gradient, from: from, to: to, space: blendSpace) }
    }

    func beginClone(at d: Vec3) {
        guard let target = editTarget, let source = cloneSource else { return }
        // Instantané : le clonage lit l'état d'avant le trait, jamais ce qu'il vient d'écrire.
        cloneSampler = LayerSampler(target.duplicate())
        cloneRotation = Sphere.rotation(from: d, to: source)
    }

    func applyClone(_ centers: [Vec3], pressure: Double) {
        guard let sampler = cloneSampler else { return }
        let rotation = cloneRotation
        for center in centers {
            let dab = dab(at: center, pressure: pressure)
            canvas?.edit { $0.clone(dab, from: sampler, rotation: rotation) }
        }
    }

    func applySmudge(_ centers: [Vec3], pressure: Double) {
        let strength = Float(smudgeStrength)
        for center in centers {
            let images = symmetry.images(of: center)
            for (i, image) in images.enumerated() where i < smudgePrevious.count {
                let previous = smudgePrevious[i]
                let dab = dab(at: image, pressure: pressure)
                canvas?.edit { $0.smudge(dab, from: previous, strength: strength) }
                smudgePrevious[i] = image
            }
        }
    }

    /// Comme le pinceau : la couleur utilisée rejoint les récentes.
    private func rememberColorIfNeeded() {
        rememberColor()
    }

    // MARK: - Symétrie

    func setSymmetry(_ kind: SymmetrySettings.Kind) {
        symmetry = SymmetrySettings(kind: kind, count: symmetry.count, axisYaw: view.yaw)
    }

    func setSymmetryCount(_ count: Int) {
        symmetry.count = max(2, min(24, count))
    }

    // MARK: - Rotation de la sphère

    var previewRotation: simd_double3x3 {
        let r = sphereRotation * .pi / 180
        return ViewState.rotation(yaw: r.x, pitch: r.y, roll: r.z)
    }

    /// Applique l'aperçu à tous les calques et masques (une seule entrée d'historique).
    func applySphereRotation() {
        strokeCancelled()
        let rotation = previewRotation
        defer {
            sphereRotation = .zero
            showRotation = false
        }
        guard sphereRotation != .zero else { return }
        if warp == nil, let device { warp = try? WarpEngine(device: device) }
        var changes: [(layerID: UUID, deltas: [TileDelta])] = []
        for layer in stack.allTiledLayers {
            let deltas: [TileDelta]
            if let warp, layer.format == .rgba16Float, let result = try? warp.rotate(layer, by: rotation) {
                deltas = result
            } else {
                layer.beginOperation()
                layer.rotateContent(rotation)
                deltas = layer.endOperation()
            }
            if !deltas.isEmpty { changes.append((layer.id, deltas)) }
        }
        guard let first = changes.first else { return }
        history.record(HistoryEntry(name: "Rotation de la sphère", layerID: first.layerID, deltas: first.deltas,
                                    otherLayers: Array(changes.dropFirst())))
        refreshHistory()
        structureChanged()
    }
}

struct ToolPicker: View {
    @Bindable var session: CanvasSession

    var body: some View {
        Menu {
            ForEach(PaintTool.allCases, id: \.self) { tool in
                Button(tool.label, systemImage: tool.symbol) { session.tool = tool }
            }
        } label: {
            Label(session.tool.label, systemImage: session.tool.symbol)
        }
        .fixedSize()
    }
}

/// Réglages propres à l'outil courant.
struct ToolOptions: View {
    @Bindable var session: CanvasSession

    var body: some View {
        switch session.tool {
        case .brush, .eraser:
            Menu("Pression") {
                Toggle("Pression → taille", isOn: $session.settings.pressureAffectsSize)
                Toggle("Pression → opacité", isOn: $session.settings.pressureAffectsOpacity)
                Toggle("QuickShape (tracer puis maintenir)", isOn: $session.quickShapeEnabled)
            }
            .fixedSize()
        case .liquify:
            LiquifyOptions(session: session)
        case .smudge:
            labeledSlider("Force", value: $session.smudgeStrength, range: 0.05...1)
        case .clone:
            Button(session.cloneSource == nil ? "Touche la source" : "Nouvelle source") { session.cloneSource = nil }
                .disabled(session.cloneSource == nil)
                .fixedSize()
        case .fill:
            labeledSlider("Seuil", value: $session.fillThreshold, range: 0...0.6)
        case .gradient:
            Picker("Forme", selection: $session.gradientShape) {
                ForEach(SphericalGradient.Shape.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
        case .select:
            SelectionOptions(session: session)
        case .effect:
            Text("Peins l'effet filtré").font(.caption).foregroundStyle(.secondary).fixedSize()
        }
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) \(Int(value.wrappedValue * 100)) %").font(.caption)
            Slider(value: value, in: range)
        }
        .frame(width: 130)
    }
}

/// Symétrie, guides et rotation de la sphère.
struct SphereToolsMenus: View {
    @Bindable var session: CanvasSession

    var body: some View {
        Menu {
            ForEach(SymmetrySettings.Kind.allCases, id: \.self) { kind in
                Button(kind.label) { session.setSymmetry(kind) }
            }
            if session.symmetry.kind == .radial || session.symmetry.kind == .kaleidoscope {
                Stepper("Copies : \(session.symmetry.count)", value: Binding(get: { session.symmetry.count },
                                                                              set: { session.setSymmetryCount($0) }), in: 2...24)
            }
        } label: {
            Label(session.symmetry.kind == .none ? "Symétrie" : session.symmetry.kind.label,
                  systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
        }
        .fixedSize()

        Menu {
            Toggle("Afficher les guides", isOn: $session.guidesEnabled)
            Picker("Espacement", selection: $session.guideSpacing) {
                ForEach([10.0, 15.0, 30.0, 45.0], id: \.self) { Text("\(Int($0))°").tag($0) }
            }
        } label: {
            Label("Guides", systemImage: "globe.europe.africa")
        }
        .fixedSize()

        Button("Texte", systemImage: "textformat") { session.showTextSheet = true }
            .labelStyle(.iconOnly)
            .sheet(isPresented: $session.showTextSheet) { TextSheet(session: session) }

        Button("Tourner la sphère", systemImage: "rotate.3d") { session.showRotation = true }
            .labelStyle(.iconOnly)
            .popover(isPresented: $session.showRotation) {
                SphereRotationPanel(session: session)
                    .padding(18)
                    .frame(width: 320)
            }
    }
}

/// Lacet, tangage et roulis de tout le contenu, avec aperçu immédiat (le shader tourne la lecture, pas les pixels).
struct SphereRotationPanel: View {
    @Bindable var session: CanvasSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rotation de la sphère").font(.headline)
            Text("Déplace le soleil ou recale l'horizon. Tous les calques tournent ensemble ; l'aperçu est immédiat.")
                .font(.caption)
                .foregroundStyle(.secondary)
            axis("Lacet", \.x)
            axis("Tangage", \.y)
            axis("Roulis", \.z)
            HStack {
                Button("Réinitialiser") { session.sphereRotation = .zero }
                Spacer()
                Button("Appliquer") { session.applySphereRotation() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.sphereRotation == .zero)
            }
        }
    }

    private func axis(_ title: String, _ keyPath: WritableKeyPath<SIMD3<Double>, Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) \(Int(session.sphereRotation[keyPath: keyPath]))°").font(.caption).monospacedDigit()
            Slider(value: Binding(get: { session.sphereRotation[keyPath: keyPath] },
                                  set: { session.sphereRotation[keyPath: keyPath] = $0.rounded() }), in: -180...180)
        }
    }
}
