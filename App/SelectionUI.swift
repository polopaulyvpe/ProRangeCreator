import PRCore
import PREngine
import PRStorage
import simd
import SwiftUI

enum SelectionKind: String, CaseIterable {
    case rectangle, ellipse, freehand, automatic

    var label: String {
        switch self {
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .freehand: "Main levée"
        case .automatic: "Automatique"
        }
    }

    var symbol: String {
        switch self {
        case .rectangle: "rectangle.dashed"
        case .ellipse: "circle.dashed"
        case .freehand: "lasso"
        case .automatic: "wand.and.stars"
        }
    }
}

/// L'historique peut restaurer la pile et la sélection.
final class SessionHistoryTarget: HistoryTarget {
    let stack: LayerStack
    let selection: SelectionMask?

    init(stack: LayerStack, selection: SelectionMask?) {
        self.stack = stack
        self.selection = selection
    }

    func tiledLayer(id: UUID) -> TiledLayer? {
        if let selection, selection.layer.id == id { return selection.layer }
        return stack.tiledLayer(id: id)
    }

    func restoreStructure(_ snapshot: [StackItem]) {
        stack.restoreStructure(snapshot)
    }
}

extension CanvasSession {
    private func makeSelectionIfNeeded() -> SelectionMask {
        if let selection { return selection }
        let mask = SelectionMask(width: stack.width, height: stack.height)
        selection = mask
        return mask
    }

    /// Modifie la sélection et l'enregistre dans l'historique.
    private func recordSelection(_ name: String, _ body: (SelectionMask) -> Void) {
        strokeCancelled()
        let mask = makeSelectionIfNeeded()
        mask.layer.beginOperation()
        body(mask)
        let deltas = mask.layer.endOperation()
        if !deltas.isEmpty {
            history.record(HistoryEntry(name: name, layerID: mask.layer.id, deltas: deltas))
            refreshHistory()
        }
        selectionUpdated()
    }

    /// Après tout changement de la sélection : affichage, chemin de peinture.
    func selectionUpdated() {
        guard let selection else { return }
        selection.invalidateCache()
        let visible = !selection.isEmpty
        if visible != hasSelection || (visible && canvas?.selection !== selection) {
            // Présence de la sélection changée : chemin de peinture et caches à revoir.
            canvas?.selection = visible ? selection : nil
        } else if visible {
            canvas?.selectionChanged()
        }
        hasSelection = visible
    }

    // MARK: - Gestes

    func selectionBegan(ndc: SIMD2<Double>, direction: Vec3) {
        if selectionKind == .automatic {
            guard let target = editTarget else { return }
            let mask = target.floodMask(from: direction, threshold: Float(selectionThreshold))
            recordSelection("Sélection automatique") { $0.apply(mask, mode: selectionCombine) }
            return
        }
        selectionDrag = [ndc]
    }

    func selectionMoved(ndc: SIMD2<Double>) {
        guard !selectionDrag.isEmpty else { return }
        if selectionKind == .freehand {
            if let last = selectionDrag.last, simd_distance(last, ndc) > 0.004 { selectionDrag.append(ndc) }
        } else {
            selectionDrag = [selectionDrag[0], ndc]
        }
    }

    func selectionEnded() {
        defer { selectionDrag = [] }
        guard selectionDrag.count >= 2, let first = selectionDrag.first, let last = selectionDrag.last else { return }
        let shape: SelectionShape
        switch selectionKind {
        case .rectangle: shape = .rectangle(first, last)
        case .ellipse: shape = .ellipse(first, last)
        case .freehand:
            guard selectionDrag.count >= 3 else { return }
            shape = .polygon(selectionDrag)
        case .automatic: return
        }
        let projection = view.parameters(aspect: lastAspect)
        recordSelection("Sélection") { $0.apply(shape, in: projection, mode: selectionCombine) }
    }

    func invertSelection() { recordSelection("Inverser la sélection") { $0.invert() } }
    func selectAll() { recordSelection("Tout sélectionner") { $0.selectAll() } }
    func clearSelection() { recordSelection("Désélectionner") { $0.clear() } }

    func featherSelection(degrees: Double) {
        guard hasSelection else { return }
        recordSelection("Adoucir") { $0.feather(radius: degrees * .pi / 180) }
    }

    // MARK: - Transformation

    func startTransform() {
        strokeCancelled()
        guard let target = editTarget else { return }
        let origin = (hasSelection ? selection?.centroid() : nil) ?? view.direction(atNDC: .zero, aspect: lastAspect) ?? [0, 0, -1]
        canvas?.setFloating(target.masked(by: hasSelection ? selection : nil))
        transform = SphericalTransform(origin: origin)
    }

    func moveTransform(to d: Vec3) {
        transform?.target = d
    }

    func applyTransform() {
        guard let t = transform, let target = editTarget else { return }
        defer { cancelTransform() }
        guard !t.isIdentity else { return }
        let mask = hasSelection ? selection : nil
        target.beginOperation()
        target.applyTransform(t, selection: mask)
        let deltas = target.endOperation()
        var others: [(layerID: UUID, deltas: [TileDelta])] = []
        if let mask {
            mask.layer.beginOperation()
            mask.transform(t)
            let maskDeltas = mask.layer.endOperation()
            if !maskDeltas.isEmpty { others.append((mask.layer.id, maskDeltas)) }
        }
        guard !deltas.isEmpty || !others.isEmpty else { return }
        if deltas.isEmpty, let first = others.first {
            history.record(HistoryEntry(name: "Transformer", layerID: first.layerID, deltas: first.deltas))
        } else {
            history.record(HistoryEntry(name: "Transformer", layerID: target.id, deltas: deltas, otherLayers: others))
        }
        refreshHistory()
        selectionUpdated()
        structureChanged()
    }

    func cancelTransform() {
        guard transform != nil else { return }
        transform = nil
        canvas?.setFloating(nil)
    }
}

/// Tracé de sélection en cours, par-dessus la toile.
struct SelectionDragOverlay: View {
    let session: CanvasSession

    var body: some View {
        GeometryReader { geo in
            let points = session.selectionDrag.map { p in
                CGPoint(x: (p.x + 1) / 2 * geo.size.width, y: (1 - p.y) / 2 * geo.size.height)
            }
            Path { path in
                guard let first = points.first, let last = points.last, points.count >= 2 else { return }
                switch session.selectionKind {
                case .rectangle:
                    path.addRect(CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                                        width: abs(last.x - first.x), height: abs(last.y - first.y)))
                case .ellipse:
                    path.addEllipse(in: CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                                               width: abs(last.x - first.x), height: abs(last.y - first.y)))
                case .freehand:
                    path.addLines(points)
                    path.closeSubpath()
                case .automatic:
                    break
                }
            }
            .stroke(.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .shadow(color: .black.opacity(0.6), radius: 1)
        }
    }
}

/// Réglages de l'outil Sélection.
struct SelectionOptions: View {
    @Bindable var session: CanvasSession

    var body: some View {
        Picker("Forme", selection: $session.selectionKind) {
            ForEach(SelectionKind.allCases, id: \.self) { Image(systemName: $0.symbol).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 170)

        Picker("Combinaison", selection: $session.selectionCombine) {
            ForEach(SelectionCombine.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.menu)
        .fixedSize()

        Menu("Sélection") {
            Button("Tout sélectionner") { session.selectAll() }
            Button("Inverser") { session.invertSelection() }
                .disabled(!session.hasSelection)
            Menu("Adoucir") {
                ForEach([0.5, 1.0, 3.0, 10.0], id: \.self) { degrees in
                    Button("\(degrees, format: .number.precision(.fractionLength(0...1)))°") { session.featherSelection(degrees: degrees) }
                }
            }
            .disabled(!session.hasSelection)
            Button("Désélectionner") { session.clearSelection() }
                .disabled(!session.hasSelection)
            if session.selectionKind == .automatic {
                Picker("Seuil", selection: $session.selectionThreshold) {
                    ForEach([0.02, 0.05, 0.1, 0.2, 0.4], id: \.self) { Text("\(Int($0 * 100)) %").tag($0) }
                }
            }
        }
        .fixedSize()

        Button("Transformer", systemImage: "arrow.up.and.down.and.arrow.left.and.right") { session.startTransform() }
            .disabled(session.transform != nil)
            .fixedSize()
    }
}

/// Échelle et rotation de la transformation en cours ; glisser sur la toile déplace le contenu.
struct TransformPanel: View {
    @Bindable var session: CanvasSession
    @State private var uniform = true

    var body: some View {
        if let transform = session.transform {
            HStack(spacing: 14) {
                Text("Glisse pour déplacer").font(.caption).foregroundStyle(.secondary)
                Toggle("Uniforme", isOn: $uniform).fixedSize()
                slider("Échelle\(uniform ? "" : " X")", value: transform.scale.x) { value in
                    session.transform?.scale.x = value
                    if uniform { session.transform?.scale.y = value }
                }
                if !uniform {
                    slider("Échelle Y", value: transform.scale.y) { session.transform?.scale.y = $0 }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rotation \(Int(transform.angle * 180 / .pi))°").font(.caption).monospacedDigit()
                    Slider(value: Binding(get: { transform.angle * 180 / .pi },
                                          set: { session.transform?.angle = $0.rounded() * .pi / 180 }), in: -180...180)
                }
                .frame(width: 140)
                Button("Annuler") { session.cancelTransform() }
                Button("Appliquer") { session.applyTransform() }
                    .buttonStyle(.borderedProminent)
            }
            .font(.callout)
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func slider(_ title: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) \(Int(value * 100)) %").font(.caption).monospacedDigit()
            Slider(value: Binding(get: { log2(value) }, set: { set(exp2($0)) }), in: -3...2)
        }
        .frame(width: 140)
    }
}
