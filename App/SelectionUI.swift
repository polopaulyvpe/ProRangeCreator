import PRCore
import PREngine
import PRStorage
import simd
import SwiftUI

enum SelectionKind: String, CaseIterable {
    case automatic, freehand, rectangle, ellipse

    var label: String {
        switch self {
        case .automatic: "Automatique"
        case .freehand: "À main levée"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        }
    }

    var symbol: String {
        switch self {
        case .automatic: "wand.and.stars"
        case .freehand: "lasso"
        case .rectangle: "rectangle.fill"
        case .ellipse: "oval.fill"
        }
    }
}

/// Sélection mise de côté (Enregistrer et charger), le temps de la session.
struct SavedSelection: Identifiable {
    let id = UUID()
    let name: String
    let layer: TiledLayer
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

/// Point d'écran (points, origine en haut à gauche) d'une direction, dans une vue de taille `size`.
func screenPoint(of d: Vec3, _ parameters: ProjectionParameters, _ size: CGSize) -> CGPoint? {
    parameters.ndc(of: d).map { CGPoint(x: ($0.x + 1) / 2 * size.width, y: (1 - $0.y) / 2 * size.height) }
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

    private var currentParameters: ProjectionParameters { view.parameters(aspect: lastAspect) }

    /// Distance à l'écran (points) entre deux directions ; infinie si l'une n'est pas visible.
    private func screenDistance(_ a: Vec3, _ b: Vec3) -> Double {
        let p = currentParameters
        guard let pa = screenPoint(of: a, p, viewSize), let pb = screenPoint(of: b, p, viewSize) else { return .infinity }
        return hypot(pa.x - pb.x, pa.y - pb.y)
    }

    // MARK: - Gestes

    func selectionBegan(ndc: SIMD2<Double>) {
        selectionTouchActive = true
        let d = view.direction(atNDC: ndc, aspect: lastAspect)
        switch selectionKind {
        case .automatic:
            guard let d else { return }
            automaticStart = (ndc, d, selectionThreshold)
        case .freehand:
            guard let d else { return }
            lassoTouchStart = lassoPoints.count
            // Toucher le point de départ (gris) ferme le tracé.
            if lassoPoints.count >= 3, let first = lassoPoints.first, screenDistance(first, d) < 22 {
                lassoClosing = true
                return
            }
            lassoClosing = false
            lassoPoints.append(d)
        case .rectangle, .ellipse:
            selectionDrag = [ndc]
        }
    }

    func selectionMoved(ndc: SIMD2<Double>) {
        switch selectionKind {
        case .automatic:
            guard let start = automaticStart else { return }
            // Glisser vers la droite ou la gauche règle le seuil, appliqué au lever.
            let dx = (ndc.x - start.ndc.x) * viewSize.width / 2
            selectionThreshold = min(1, max(0.005, start.threshold + dx / 700))
            showToast("Seuil de sélection : \(Int((selectionThreshold * 100).rounded())) %")
        case .freehand:
            guard !lassoClosing, let d = view.direction(atNDC: ndc, aspect: lastAspect) else { return }
            if let last = lassoPoints.last, screenDistance(last, d) < 3 { return }
            lassoPoints.append(d)
        case .rectangle, .ellipse:
            guard !selectionDrag.isEmpty else { return }
            selectionDrag = [selectionDrag[0], ndc]
        }
    }

    func selectionEnded() {
        selectionTouchActive = false
        switch selectionKind {
        case .automatic:
            guard let start = automaticStart, let target = readTarget else { return }
            automaticStart = nil
            let mask = target.floodMask(from: start.direction, threshold: Float(selectionThreshold))
            let mode = selectionCombine
            recordSelection("Sélection automatique") { $0.apply(mask, mode: mode) }
            afterSelectionShape()
        case .freehand:
            // Lever le crayon près du point de départ ferme aussi le tracé ; sinon il reste ouvert (toucher ajoute un sommet).
            if lassoClosing || (lassoPoints.count >= 3 && screenDistance(lassoPoints[0], lassoPoints[lassoPoints.count - 1]) < 22) {
                closeLasso()
            }
            lassoClosing = false
        case .rectangle, .ellipse:
            defer { selectionDrag = [] }
            guard selectionDrag.count == 2 else { return }
            let (first, last) = (selectionDrag[0], selectionDrag[1])
            guard simd_distance(first, last) > 0.005 else { return }
            let shape: SelectionShape = selectionKind == .rectangle ? .rectangle(first, last) : .ellipse(first, last)
            let projection = currentParameters
            let mode = selectionCombine
            recordSelection("Sélection") { $0.apply(shape, in: projection, mode: mode) }
            afterSelectionShape()
        }
    }

    /// Second doigt posé : le geste de sélection commencé est oublié.
    func selectionCancelled() {
        selectionTouchActive = false
        if lassoTouchStart <= lassoPoints.count { lassoPoints.removeLast(lassoPoints.count - lassoTouchStart) }
        lassoClosing = false
        selectionDrag = []
        automaticStart = nil
    }

    /// Ferme le tracé à main levée et l'ajoute à la sélection (ou l'en retire).
    func closeLasso() {
        let points = lassoPoints
        lassoPoints = []
        lassoTouchStart = 0
        let projection = currentParameters
        let polygon = points.compactMap { projection.ndc(of: $0) }
        guard polygon.count >= 3 else { return }
        let mode = selectionCombine
        recordSelection("Sélection") { $0.apply(.polygon(polygon), in: projection, mode: mode) }
        afterSelectionShape()
    }

    private func afterSelectionShape() {
        if selectionColorFill { fillSelectionWithColor() }
    }

    // MARK: - Actions de la barre

    func invertSelection() { recordSelection("Inverser la sélection") { $0.invert() } }
    func selectAll() { recordSelection("Tout sélectionner") { $0.selectAll() } }

    /// Effacer : la sélection disparaît (le tracé en cours aussi).
    func clearSelection() {
        lassoPoints = []
        guard hasSelection else { return }
        recordSelection("Désélectionner") { $0.clear() }
    }

    func featherSelection(degrees: Double) {
        guard hasSelection, degrees > 0 else { return }
        recordSelection("Contour progressif") { $0.feather(radius: degrees * .pi / 180) }
    }

    /// Remplissage de couleur : la sélection est peinte de la couleur courante sur le calque actif.
    func fillSelectionWithColor() {
        guard hasSelection, let selection, let target = editTarget else { return }
        strokeCancelled()
        let dab = SphericalDab(center: [0, 0, -1], radius: 1, hardness: 1, color: SIMD4<Float>(linearColor, 1))
        let space = blendSpace
        target.beginOperation()
        var touched = Set<TileCoord>()
        for coord in selection.layer.storedTiles {
            guard let values = selection.tileValues(coord) else { continue }
            var pixels = target.tileFloatPixels(coord)
            for i in pixels.indices where values[i] > 0 {
                SphericalRasterizer.apply(dab, coverage: values[i], to: &pixels[i], space: space)
            }
            target.replaceTile(coord, withPixels: pixels)
            touched.insert(coord)
        }
        let deltas = target.endOperation()
        guard !deltas.isEmpty else { return }
        history.record(HistoryEntry(name: "Remplissage de couleur", layerID: target.id, deltas: deltas))
        canvas?.invalidate(touched, layerID: target.id)
        refreshHistory()
        rememberColor()
    }

    /// Sélectionner (options du calque) : la sélection devient le contenu du calque, et l'outil Sélection s'ouvre.
    func selectLayerContent() {
        guard let source = readTarget else { return }
        applyTransform()
        recordSelection("Sélectionner le calque") { $0.selectContent(of: source) }
        guard hasSelection else {
            showToast("Calque vide : rien à sélectionner")
            return
        }
        tool = .select
        showLayers = false
    }

    /// Copier et coller : le contenu sélectionné part sur un nouveau calque, au-dessus, prêt à être transformé.
    func copyPasteSelection() {
        guard hasSelection, let selection, let source = readTarget, stack.canAddLayer else { return }
        strokeCancelled()
        let copy = source.masked(by: selection)
        let before = stack.items
        guard let item = stack.addLayer(above: activeID, name: "Copie de la sélection"), let layer = item.layer else { return }
        layer.beginOperation()
        for coord in copy.storedTiles { layer.replaceTile(coord, withPixels: copy.tileFloatPixels(coord)) }
        let deltas = layer.endOperation()
        selection.layer.beginOperation()
        selection.clear()
        let selectionDeltas = selection.layer.endOperation()
        history.record(HistoryEntry(name: "Copier et coller", layerID: layer.id, deltas: deltas, structure: (before, stack.items),
                                    otherLayers: selectionDeltas.isEmpty ? [] : [(selection.layer.id, selectionDeltas)]))
        refreshHistory()
        selectionUpdated()
        selectLayer(item.id)
        showToast("Nouveau calque à partir de la sélection")
        startTransform()
    }

    /// Met la sélection de côté (Enregistrer et charger).
    func saveSelection() {
        guard hasSelection, let selection else { return }
        savedSelections.append(SavedSelection(name: "Sélection \(savedSelections.count + 1)", layer: selection.layer.duplicate()))
    }

    /// Recharge une sélection mise de côté à la place de l'actuelle.
    func loadSelection(_ saved: SavedSelection) {
        recordSelection("Charger la sélection") { mask in
            mask.clear()
            for coord in saved.layer.storedTiles { mask.layer.replaceTile(coord, withPixels: saved.layer.tileFloatPixels(coord)) }
        }
    }
}

// MARK: - Affichage du tracé

/// Tracé en cours par-dessus la toile : pointillés noirs, point de départ gris (le toucher ferme le tracé).
/// Les points du tracé à main levée sont sur la sphère : il suit la vue si on navigue pendant qu'on le trace.
struct SelectionDragOverlay: View {
    let session: CanvasSession

    var body: some View {
        if session.tool == .select, !session.lassoPoints.isEmpty || session.selectionDrag.count == 2 {
            TimelineView(.animation) { _ in
                GeometryReader { geo in
                    let parameters = session.view.parameters(aspect: Double(geo.size.width / max(geo.size.height, 1)))
                    let lasso = session.lassoPoints.compactMap { screenPoint(of: $0, parameters, geo.size) }
                    let drag = session.selectionDrag.map { CGPoint(x: ($0.x + 1) / 2 * geo.size.width, y: (1 - $0.y) / 2 * geo.size.height) }
                    let path = Path { path in
                        if session.selectionKind == .freehand {
                            if lasso.count >= 2 { path.addLines(lasso) }
                        } else if drag.count == 2 {
                            let rect = CGRect(x: min(drag[0].x, drag[1].x), y: min(drag[0].y, drag[1].y),
                                              width: abs(drag[1].x - drag[0].x), height: abs(drag[1].y - drag[0].y))
                            if session.selectionKind == .ellipse { path.addEllipse(in: rect) } else { path.addRect(rect) }
                        }
                    }
                    ZStack {
                        path.stroke(.white.opacity(0.7), lineWidth: 2.5)
                        path.stroke(.black, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                        if session.selectionKind == .freehand, let start = lasso.first {
                            Circle().fill(Color(white: 0.78))
                                .frame(width: 18, height: 18)
                                .shadow(color: .black.opacity(0.25), radius: 1.5)
                                .position(start)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Barre de l'outil Sélection

/// Barre du bas de l'outil Sélection : la forme du tracé, puis les actions.
struct SelectionToolbar: View {
    @Bindable var session: CanvasSession

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 4) {
                ForEach(SelectionKind.allCases, id: \.self) { kind in
                    Button {
                        if session.selectionKind == .freehand, kind != .freehand { session.lassoPoints = [] }
                        session.selectionKind = kind
                    } label: {
                        Label(kind.label, systemImage: kind.symbol)
                            .font(.system(size: 16))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .frame(minWidth: 150)
                            .background(Capsule().fill(session.selectionKind == kind ? Color.accentColor : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Capsule().fill(Color(white: 0.24)))

            HStack(spacing: 0) {
                BarAction("Ajouter", symbol: "plus.rectangle.fill", highlighted: session.selectionCombine == .add) {
                    session.selectionCombine = .add
                }
                BarAction("Enlever", symbol: "minus.rectangle.fill", highlighted: session.selectionCombine == .subtract) {
                    session.selectionCombine = .subtract
                }
                BarAction("Inverser", symbol: "square.lefthalf.filled", enabled: session.hasSelection) { session.invertSelection() }
                BarAction("Copier et coller", symbol: "circle.lefthalf.filled", enabled: session.hasSelection) {
                    session.copyPasteSelection()
                }
                BarAction("Contour progressif", symbol: "circle.dashed.inset.filled", enabled: session.hasSelection) {
                    session.showFeather = true
                }
                .popover(isPresented: $session.showFeather) { FeatherPanel(session: session) }
                BarAction("Enregistrer et charger", symbol: "heart.fill") { session.showSavedSelections = true }
                    .popover(isPresented: $session.showSavedSelections) { SavedSelectionsPanel(session: session) }
                BarAction("Remplissage de couleur", symbol: "drop.fill", highlighted: session.selectionColorFill) {
                    session.selectionColorFill.toggle()
                    if session.selectionColorFill { session.fillSelectionWithColor() }
                }
                BarAction("Effacer", symbol: "xmark.square", enabled: session.hasSelection || !session.lassoPoints.isEmpty) {
                    session.clearSelection()
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: 1180)
        .background(RoundedRectangle(cornerRadius: 30).fill(Color(white: 0.15)))
        .environment(\.colorScheme, .dark)
    }
}

/// Action de barre du bas : icône au-dessus de son nom ; bleue quand elle est active, grisée quand elle est indisponible.
struct BarAction: View {
    let title: String
    let symbol: String
    var highlighted = false
    var enabled = true
    let action: () -> Void

    init(_ title: String, symbol: String, highlighted: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.highlighted = highlighted
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 21))
                    .foregroundStyle(highlighted ? Color.accentColor : .white)
                    .frame(height: 26)
                Text(title).font(.system(size: 14)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Contour progressif : quantité d'adoucissement du bord de la sélection.
struct FeatherPanel: View {
    @Bindable var session: CanvasSession
    @State private var amount = 20.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Contour progressif").font(.headline)
            HStack {
                Text("Quantité")
                Slider(value: $amount, in: 0...100, step: 1)
                Text("\(Int(amount)) %").monospacedDigit().frame(width: 52, alignment: .trailing)
            }
            HStack {
                Spacer()
                Button("Appliquer") {
                    // 100 % : bord adouci sur 6°.
                    session.featherSelection(degrees: amount / 100 * 6)
                    session.showFeather = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// Enregistrer et charger : sélections mises de côté pendant la session.
struct SavedSelectionsPanel: View {
    @Bindable var session: CanvasSession

    var body: some View {
        NavigationStack {
            List {
                ForEach(session.savedSelections) { saved in
                    Button(saved.name) {
                        session.loadSelection(saved)
                        session.showSavedSelections = false
                    }
                }
                .onDelete { session.savedSelections.remove(atOffsets: $0) }
                if session.savedSelections.isEmpty {
                    Text("Aucune sélection enregistrée.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Sélections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Enregistrer", systemImage: "plus") { session.saveSelection() }
                    .disabled(!session.hasSelection)
            }
        }
        .frame(width: 340, height: 380)
    }
}
