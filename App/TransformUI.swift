import PRCore
import PREngine
import PRStorage
import simd
import SwiftUI

/// Façons de transformer (barre du bas de l'outil Transformer).
enum TransformMode: String, CaseIterable {
    case freeform, uniform, distort, warp

    var label: String {
        switch self {
        case .freeform: "Freeform"
        case .uniform: "Uniforme"
        case .distort: "Déformation"
        case .warp: "Déformer"
        }
    }

    var symbol: String {
        switch self {
        case .freeform: "arrow.up.left.and.arrow.down.right"
        case .uniform: "aspectratio"
        case .distort: "skew"
        case .warp: "square.grid.3x3"
        }
    }
}

/// Poignées de la boîte de transformation.
enum TransformHandle: Hashable {
    /// Coins : haut gauche, haut droit, bas droit, bas gauche.
    case corner(Int)
    /// Milieux des côtés : haut, droit, bas, gauche.
    case edge(Int)
    /// Poignée verte : rotation du contenu.
    case rotate
    /// Poignée jaune : rotation de la boîte seule.
    case box
    /// Maillage avancé : point de contrôle `j * 4 + i`.
    case mesh(Int)
}

/// Ce que le doigt tient pendant un geste de transformation.
enum TransformGrab {
    case move
    case handle(TransformHandle)
    /// Déformer : point de la boîte attrapé (carré unité).
    case warp(SIMD2<Double>)
}

struct TransformDrag {
    let grab: TransformGrab
    let initial: FreeTransform
    let startNDC: SIMD2<Double>
    let startDirection: Vec3
    let startPlane: SIMD2<Double>?
}

/// Contenu découpé pendant la transformation : il flotte au-dessus de la toile jusqu'à ce qu'on le recolle.
struct TransformWork {
    let target: TiledLayer
    let floating: TiledLayer
    /// État d'avant la découpe des tuiles changées : une seule entrée d'historique à la fin, ou tout remettre.
    let cut: [TileCoord: TileState]
}

/// Ce que la vue dessine par-dessus la toile pendant une transformation (en points d'écran).
struct TransformGeometry {
    var outline: [CGPoint] = []
    var grid: [[CGPoint]] = []
    var handles: [(handle: TransformHandle, point: CGPoint)] = []
    var rotateStem: (CGPoint, CGPoint)?
    var boxStem: (CGPoint, CGPoint)?
}

extension CanvasSession {
    // MARK: - Début et fin

    /// Transformer : la sélection (ou tout le calque) est découpée et flotte ; la boîte l'entoure.
    func startTransform() {
        guard transform == nil else { return }
        strokeCancelled()
        if tool == .select, !lassoPoints.isEmpty { closeLasso() }
        if refuseIfLocked() { return }
        guard let target = editTarget else { return }
        let mask = hasSelection ? selection : nil
        let samples = mask?.selectedDirections() ?? target.contentDirections()
        guard let fitted = FreeTransform.fitting(samples) else {
            showToast("Rien à transformer sur ce calque")
            return
        }
        let floating = target.masked(by: mask)
        let cut = target.cut(selection: mask)
        canvas?.invalidate(cut.keys, layerID: target.id)
        canvas?.setFloating(floating)
        transformWork = TransformWork(target: target, floating: floating, cut: cut)
        transformFromSelection = mask != nil
        transform = fitted
    }

    /// Recolle le contenu transformé : une entrée d'historique (calque et sélection).
    func applyTransform() {
        guard let t = transform, let work = transformWork else { return }
        transformDrag = nil
        if t.isIdentity {
            cancelTransform()
            return
        }
        let target = work.target
        target.beginOperation()
        target.paste(work.floating, transform: t, filter: transformFilter)
        let deltas = target.transformDeltas(cut: work.cut, pasted: target.endOperation())
        var others: [(layerID: UUID, deltas: [TileDelta])] = []
        if transformFromSelection, let mask = selection {
            mask.layer.beginOperation()
            mask.transform(t)
            let maskDeltas = mask.layer.endOperation()
            if !maskDeltas.isEmpty { others.append((mask.layer.id, maskDeltas)) }
        }
        endTransformDisplay(tiles: work.cut.keys, deltas.map(\.coord), layerID: target.id)
        if deltas.isEmpty, let first = others.first {
            history.record(HistoryEntry(name: "Transformer", layerID: first.layerID, deltas: first.deltas))
        } else if !deltas.isEmpty {
            history.record(HistoryEntry(name: "Transformer", layerID: target.id, deltas: deltas, otherLayers: others))
        }
        refreshHistory()
        selectionUpdated()
    }

    /// Abandon : le contenu découpé revient à sa place, sans entrée d'historique.
    func cancelTransform() {
        guard transform != nil, let work = transformWork else {
            transform = nil
            return
        }
        for (coord, state) in work.cut { work.target.restore(state, at: coord) }
        endTransformDisplay(tiles: work.cut.keys, [], layerID: work.target.id)
    }

    private func endTransformDisplay(tiles: some Sequence<TileCoord>, _ more: [TileCoord], layerID: UUID) {
        canvas?.invalidate(Set(tiles).union(more), layerID: layerID)
        canvas?.setFloating(nil)
        transform = nil
        transformWork = nil
        transformDrag = nil
        transformSize = nil
        transformFromSelection = false
    }

    /// Nouvelle pile (ouverture, nouveau projet) : la transformation en cours n'a plus de sens.
    func discardTransform() {
        transform = nil
        transformWork = nil
        transformDrag = nil
        transformSize = nil
        transformFromSelection = false
        canvas?.setFloating(nil)
    }

    // MARK: - Géométrie à l'écran

    func transformGeometry(size: CGSize, parameters: ProjectionParameters) -> TransformGeometry? {
        guard let t = transform else { return nil }
        func screen(_ w: SIMD2<Double>) -> CGPoint? {
            t.targetPoint(w).flatMap { screenPoint(of: t.direction(ofPlanePoint: $0), parameters, size) }
        }
        var g = TransformGeometry()
        let n = 24
        let edges: [(Double) -> SIMD2<Double>] = [{ [$0, 0] }, { [1, $0] }, { [1 - $0, 1] }, { [0, 1 - $0] }]
        for edge in edges {
            for k in 0..<n { if let p = screen(edge(Double(k) / Double(n))) { g.outline.append(p) } }
        }
        if let first = g.outline.first { g.outline.append(first) }
        if transformMode == .warp {
            for s in [1.0 / 3, 2.0 / 3] {
                g.grid.append((0...n).compactMap { screen([s, Double($0) / Double(n)]) })
                g.grid.append((0...n).compactMap { screen([Double($0) / Double(n), s]) })
            }
        }
        let corners: [SIMD2<Double>] = FreeTransform.unitCorners
        let mids: [SIMD2<Double>] = [[0.5, 0], [1, 0.5], [0.5, 1], [0, 0.5]]
        if transformMode == .warp {
            if transformAdvancedMesh, let h = t.homography {
                for k in 0..<16 {
                    if let q = h.apply(t.mesh.points[k]), let p = screenPoint(of: t.direction(ofPlanePoint: q), parameters, size) {
                        g.handles.append((handle: .mesh(k), point: p))
                    }
                }
            } else {
                for (i, w) in corners.enumerated() { if let p = screen(w) { g.handles.append((handle: .corner(i), point: p)) } }
            }
            return g
        }
        for (i, w) in corners.enumerated() { if let p = screen(w) { g.handles.append((handle: .corner(i), point: p)) } }
        for (i, w) in mids.enumerated() { if let p = screen(w) { g.handles.append((handle: .edge(i), point: p)) } }
        // Tiges : vers l'extérieur de la boîte, depuis le milieu du haut (rotation) et du bas (boîte seule).
        if let c = screen([0.5, 0.5]) {
            func stem(_ w: SIMD2<Double>) -> (CGPoint, CGPoint)? {
                guard let base = screen(w) else { return nil }
                let v = CGPoint(x: base.x - c.x, y: base.y - c.y)
                let length = max(hypot(v.x, v.y), 1)
                return (base, CGPoint(x: base.x + v.x / length * 34, y: base.y + v.y / length * 34))
            }
            g.rotateStem = stem([0.5, 0])
            if let top = g.rotateStem { g.handles.append((handle: .rotate, point: top.1)) }
            if transformMode != .distort, t.mesh.isIdentity {
                g.boxStem = stem([0.5, 1])
                if let bottom = g.boxStem { g.handles.append((handle: .box, point: bottom.1)) }
            }
        }
        return g
    }

    /// Taille du contenu transformé, en pixels de la toile (largeur et hauteur au milieu de la boîte).
    private func transformPixelSize(_ t: FreeTransform) -> SIMD2<Int>? {
        guard let l = t.targetPoint([0, 0.5]), let r = t.targetPoint([1, 0.5]),
              let top = t.targetPoint([0.5, 0]), let bottom = t.targetPoint([0.5, 1]) else { return nil }
        let pixel = Double.pi / Double(stack.height)
        let w = Sphere.angle(t.fromPlane(l), t.fromPlane(r)) / pixel
        let h = Sphere.angle(t.fromPlane(top), t.fromPlane(bottom)) / pixel
        return [Int(w.rounded()), Int(h.rounded())]
    }

    // MARK: - Gestes

    func transformBegan(ndc: SIMD2<Double>) {
        guard let t = transform, let d = view.direction(atNDC: ndc, aspect: lastAspect) else { return }
        let parameters = view.parameters(aspect: lastAspect)
        let touch = CGPoint(x: (ndc.x + 1) / 2 * viewSize.width, y: (1 - ndc.y) / 2 * viewSize.height)
        var grab = TransformGrab.move
        if let g = transformGeometry(size: viewSize, parameters: parameters) {
            let near = g.handles
                .map { (handle: $0.handle, distance: hypot($0.point.x - touch.x, $0.point.y - touch.y)) }
                .filter { $0.distance < 30 }
                .min { $0.distance < $1.distance }
            if let near {
                grab = .handle(near.handle)
            } else if transformMode == .warp, Self.contains(g.outline, touch), let p = t.planePoint(under: d),
                      let w = t.boxPoint(under: p) {
                grab = .warp(w)
            }
        }
        transformDrag = TransformDrag(grab: grab, initial: t, startNDC: ndc, startDirection: d, startPlane: t.planePoint(under: d))
    }

    func transformMoved(ndc: SIMD2<Double>) {
        guard let drag = transformDrag else { return }
        var t = drag.initial
        switch drag.grab {
        case .move:
            var point = ndc
            if transformSnapping {
                // Aimants : le déplacement suit l'axe horizontal ou vertical de l'écran le plus proche.
                let delta = ndc - drag.startNDC
                point = abs(delta.x * viewSize.width) >= abs(delta.y * viewSize.height)
                    ? [ndc.x, drag.startNDC.y] : [drag.startNDC.x, ndc.y]
            }
            guard let d = view.direction(atNDC: point, aspect: lastAspect) else { return }
            t.target = simd_normalize(Sphere.rotation(from: drag.startDirection, to: d) * drag.initial.target)
        case .handle(let handle):
            guard let d = view.direction(atNDC: ndc, aspect: lastAspect), let start = drag.startPlane,
                  let p = drag.initial.planePoint(under: d) else { return }
            edit(&t, handle: handle, from: start, to: p, initial: drag.initial)
        case .warp(let w):
            guard let d = view.direction(atNDC: ndc, aspect: lastAspect), let p = drag.initial.planePoint(under: d) else { return }
            t.warp(grabbed: w, to: p)
        }
        transform = t
    }

    private func edit(_ t: inout FreeTransform, handle: TransformHandle, from start: SIMD2<Double>, to p: SIMD2<Double>,
                      initial: FreeTransform) {
        switch handle {
        case .rotate, .box:
            let c = initial.center
            var angle = atan2(p.y - c.y, p.x - c.x) - atan2(start.y - c.y, start.x - c.x)
            angle = remainder(angle, 2 * .pi)
            if transformSnapping { angle = (angle / (.pi / 12)).rounded() * (.pi / 12) }
            if case .rotate = handle { t.rotate(by: angle) } else { t.rotateBox(by: angle) }
        case .corner(let i):
            switch transformMode {
            case .distort: t.moveCorner(i, to: initial.corners[i] + p - start)
            case .warp: t.warp(grabbed: FreeTransform.unitCorners[i], to: p)
            case .freeform, .uniform:
                t.scale(handle: i, to: p, from: start, initial: initial, uniform: transformMode == .uniform)
                transformSize = transformPixelSize(t)
            }
        case .edge(let e):
            if transformMode == .distort {
                t.moveEdge(e, by: p - start)
            } else {
                t.scale(handle: 4 + e, to: p, from: start, initial: initial, uniform: transformMode == .uniform)
                transformSize = transformPixelSize(t)
            }
        case .mesh(let k):
            guard let h = initial.homography?.inverse, let a = h.apply(start), let b = h.apply(p) else { return }
            t.mesh.points[k] = initial.mesh.points[k] + b - a
        }
    }

    func transformEnded() {
        transformDrag = nil
        transformSize = nil
    }

    /// Second doigt posé : le geste revient à son point de départ.
    func transformDragCancelled() {
        if let drag = transformDrag { transform = drag.initial }
        transformDrag = nil
        transformSize = nil
    }

    /// Point dans un polygone (règle pair-impair).
    static func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    // MARK: - Boutons

    func flipTransform(horizontally: Bool) { transform?.flip(horizontally: horizontally) }

    /// Un huitième de tour dans le sens des aiguilles d'une montre.
    func rotateTransform45() { transform?.rotate(by: -.pi / 4) }

    /// Adapter à la toile : le contenu remplit la vue (90 %), au centre de l'écran.
    func fitTransformToView() {
        guard var t = transform, let center = view.direction(atNDC: .zero, aspect: lastAspect) else { return }
        let parameters = view.parameters(aspect: lastAspect)
        let (ax, ay) = t.axes
        let half = parameters.tanHalfFov
        let limit = t.plane == .gnomonic ? half : atan(half)
        let s = min(2 * limit * 0.9 / max(simd_length(ay), 1e-9), 2 * limit * parameters.aspect * 0.9 / max(simd_length(ax), 1e-9))
        let c = t.center
        t.applyAffine { c + ($0 - c) * s }
        let now = t.direction(ofPlanePoint: t.center)
        t.target = simd_normalize(Sphere.rotation(from: now, to: center) * t.target)
        transform = t
    }

    func resetTransform() {
        transform?.reset()
        showToast("Transformation rétablie")
    }
}

// MARK: - Affichage

/// Boîte de transformation : pointillés, poignées bleues, verte (rotation), jaune (boîte seule), maillage, taille.
struct TransformOverlay: View {
    let session: CanvasSession

    var body: some View {
        if session.transform != nil {
            TimelineView(.animation) { _ in
                GeometryReader { geo in
                    let parameters = session.view.parameters(aspect: Double(geo.size.width / max(geo.size.height, 1)))
                    if let g = session.transformGeometry(size: geo.size, parameters: parameters) {
                        ZStack {
                            let outline = Path { $0.addLines(g.outline) }
                            outline.stroke(.white.opacity(0.6), lineWidth: 2.2)
                            outline.stroke(.black, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            ForEach(0..<g.grid.count, id: \.self) { i in
                                Path { $0.addLines(g.grid[i]) }.stroke(.black.opacity(0.7), lineWidth: 0.8)
                            }
                            if let stem = g.rotateStem {
                                Path { $0.move(to: stem.0); $0.addLine(to: stem.1) }.stroke(Color.green, lineWidth: 1.5)
                            }
                            if let stem = g.boxStem {
                                Path { $0.move(to: stem.0); $0.addLine(to: stem.1) }.stroke(Color.orange, lineWidth: 1.5)
                            }
                            ForEach(0..<g.handles.count, id: \.self) { i in
                                handleView(g.handles[i].handle).position(g.handles[i].point)
                            }
                            if let size = session.transformSize, let anchor = g.handles.first?.point {
                                SizeBadge(size: size)
                                    .position(x: min(geo.size.width - 90, anchor.x + 260), y: max(60, anchor.y + 30))
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func handleView(_ handle: TransformHandle) -> some View {
        switch handle {
        case .rotate:
            Circle().fill(Color.green).overlay(Circle().stroke(.white, lineWidth: 1.5)).frame(width: 13, height: 13)
        case .box:
            Rectangle().fill(Color.orange).overlay(Rectangle().stroke(.white, lineWidth: 1.2)).frame(width: 12, height: 12)
        default:
            Circle().fill(Color.accentColor).overlay(Circle().stroke(.white, lineWidth: 1.5)).frame(width: 13, height: 13)
        }
    }
}

/// Largeur et hauteur en pixels pendant qu'on étire.
struct SizeBadge: View {
    let size: SIMD2<Int>

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 40, verticalSpacing: 2) {
            GridRow {
                Text("Largeur").bold()
                Text("\(size.x)px").foregroundStyle(.white.opacity(0.6))
            }
            GridRow {
                Text("Hauteur").bold()
                Text("\(size.y)px").foregroundStyle(.white.opacity(0.6))
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.55).opacity(0.85)))
    }
}

// MARK: - Barre de l'outil Transformer

struct TransformToolbar: View {
    @Bindable var session: CanvasSession

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 4) {
                ForEach(TransformMode.allCases, id: \.self) { mode in
                    Button { session.transformMode = mode } label: {
                        Label(mode.label, systemImage: mode.symbol)
                            .font(.system(size: 16))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .frame(minWidth: 150)
                            .background(Capsule().fill(session.transformMode == mode ? Color.accentColor : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Capsule().fill(Color(white: 0.24)))

            HStack(spacing: 0) {
                if session.transformMode == .warp {
                    BarAction("Maillage avancé", symbol: "square.grid.3x3.fill", highlighted: session.transformAdvancedMesh) {
                        session.transformAdvancedMesh.toggle()
                    }
                } else {
                    BarAction("Aimants", symbol: "bolt.circle.fill", highlighted: session.transformSnapping) {
                        session.transformSnapping.toggle()
                    }
                }
                BarAction("Retourner horiz.", symbol: "flip.horizontal") { session.flipTransform(horizontally: true) }
                BarAction("Retourner vertic.", symbol: "flip.horizontal") { session.flipTransform(horizontally: false) }
                BarAction("Faire pivoter de 45°", symbol: "rotate.right") { session.rotateTransform45() }
                BarAction("Adapter à la toile", symbol: "arrow.up.backward.and.arrow.down.forward") { session.fitTransformToView() }
                Menu {
                    Picker("Interpolation", selection: $session.transformFilter) {
                        ForEach(ResamplingFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "checkerboard.rectangle").font(.system(size: 21)).frame(height: 26)
                        Text(session.transformFilter.label).font(.system(size: 14)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
                BarAction("Rétablir", symbol: "arrow.triangle.2.circlepath") { session.resetTransform() }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: 1040)
        .background(RoundedRectangle(cornerRadius: 30).fill(Color(white: 0.15)))
        .environment(\.colorScheme, .dark)
    }
}
