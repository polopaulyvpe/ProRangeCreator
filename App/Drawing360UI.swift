import PRCore
import simd
import SwiftUI

/// Plan proposé pour peindre en perspective.
enum PaintPlaneKind: String, CaseIterable {
    case none
    case floor
    case ceiling
    case wall

    var label: String {
        switch self {
        case .none: "Aucun"
        case .floor: "Sol"
        case .ceiling: "Plafond"
        case .wall: "Mur"
        }
    }
}

extension CanvasSession {
    /// Grille de perspective ou de plan à afficher par-dessus la toile.
    var shows360Grid: Bool {
        (perspective.isEnabled && perspective.showsGrid) || perspectiveEditing || (paintPlane != nil && paintPlaneGrid)
    }

    private var forwardDirection: Vec3 {
        view.direction(atNDC: .zero, aspect: lastAspect) ?? [0, 0, -1]
    }

    // MARK: - Perspective

    func setPerspectiveEnabled(_ enabled: Bool) {
        if enabled, perspective.points.isEmpty {
            perspective.points = PerspectiveSettings.boxPoints(yaw: view.capturedLook.yaw)
        }
        perspective.isEnabled = enabled
        scheduleAutosave()
    }

    /// Repère à trois axes, orienté selon le regard.
    func resetPerspectiveToBox() {
        perspective.points = PerspectiveSettings.boxPoints(yaw: view.capturedLook.yaw)
        perspective.isEnabled = true
        perspectiveSelection = nil
        scheduleAutosave()
    }

    /// Un seul point de fuite, droit devant.
    func resetPerspectiveToSinglePoint() {
        let point = VanishingPoint(direction: forwardDirection, isFree: true)
        perspective.points = [point]
        perspective.isEnabled = true
        perspectiveSelection = point.id
        scheduleAutosave()
    }

    func addVanishingPoint() {
        let point = VanishingPoint(direction: forwardDirection, isFree: true)
        perspective.points.append(point)
        perspective.isEnabled = true
        perspectiveSelection = point.id
        scheduleAutosave()
    }

    func deleteSelectedVanishingPoint() {
        guard let id = perspectiveSelection else { return }
        perspective.points.removeAll { $0.id == id }
        perspectiveSelection = nil
        scheduleAutosave()
    }

    /// Une poignée glissée à l'écran. `sign` = −1 pour la poignée opposée du même axe.
    func dragVanishingPoint(_ id: UUID, sign: Double, location: CGPoint, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let ndc = SIMD2<Double>(Double(location.x / size.width) * 2 - 1, 1 - Double(location.y / size.height) * 2)
        guard let d = view.direction(atNDC: ndc, aspect: Double(size.width / size.height)) else { return }
        perspective.move(id, to: d * sign)
        perspectiveSelection = id
    }

    // MARK: - Plan

    func setPaintPlane(_ kind: PaintPlaneKind) {
        paintPlaneKind = kind
        let alignment = perspective.isEnabled ? perspective.points.map(\.direction) : []
        func make(_ normal: Vec3) -> PaintPlane {
            PaintPlane(normal: normal, gridAxis: alignment.first { abs(simd_dot($0, normal)) < 0.7 })
        }
        switch kind {
        case .none:
            paintPlane = nil
        case .floor:
            paintPlane = make([0, -1, 0])
        case .ceiling:
            paintPlane = make([0, 1, 0])
        case .wall:
            paintPlane = make(wallNormal(alignment: alignment))
        }
    }

    /// Mur en face du regard, calé sur l'axe de perspective le plus proche s'il y en a un.
    private func wallNormal(alignment: [Vec3]) -> Vec3 {
        let forward = forwardDirection
        var flat = Vec3(forward.x, 0, forward.z)
        if simd_length(flat) < 1e-3 {
            let yaw = view.capturedLook.yaw
            flat = [sin(yaw), 0, -cos(yaw)]
        }
        flat = simd_normalize(flat)
        var best = flat
        var bestScore = 0.5
        for axis in alignment where abs(axis.y) < 0.7 {
            for candidate in [axis, -axis] {
                let score = simd_dot(candidate, flat)
                if score > bestScore {
                    bestScore = score
                    best = candidate
                }
            }
        }
        return best
    }

    // MARK: - Regards

    func saveBookmark() {
        bookmarks.append(ViewBookmark(name: "Regard \(bookmarks.count + 1)", look: view.capturedLook))
        showToast("Regard enregistré")
        scheduleAutosave()
    }

    func renameBookmark(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[index].name = trimmed
        scheduleAutosave()
    }

    func deleteBookmark(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        scheduleAutosave()
    }

    func goToNextBookmark() {
        guard !bookmarks.isEmpty else {
            showToast("Aucun regard enregistré")
            return
        }
        bookmarkIndex = (bookmarkIndex + 1) % bookmarks.count
        go(to: bookmarks[bookmarkIndex].look)
        showToast(bookmarks[bookmarkIndex].name)
    }
}

// MARK: - Panneau

struct Drawing360Panel: View {
    @Bindable var session: CanvasSession
    @State private var renamingID: UUID?
    @State private var newName = ""

    var body: some View {
        PanelContainer(title: "Dessin 360", width: 400) {
            perspectiveSection
            planeSection
            PanelSection {
                PanelRow("Tourner ce calque…", symbol: "rotate.3d") {
                    session.show360Panel = false
                    session.openLayerRotation()
                }
            }
            lookSection
        }
        .alert("Renommer le regard", isPresented: Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })) {
            TextField("Nom", text: $newName)
            Button("Renommer") {
                if let renamingID { session.renameBookmark(renamingID, to: newName) }
            }
            Button("Annuler", role: .cancel) {}
        }
    }

    private var perspectiveSection: some View {
        PanelSection {
            PanelToggle("Caler le trait sur la perspective",
                        isOn: Binding(get: { session.perspective.isEnabled }, set: { session.setPerspectiveEnabled($0) }))
            PanelToggle("Afficher la grille de perspective", isOn: $session.perspective.showsGrid)
            Menu {
                Button("Trois axes (pièce, rue)") { session.resetPerspectiveToBox() }
                Button("Point unique (couloir)") { session.resetPerspectiveToSinglePoint() }
            } label: {
                PanelRowLabel("Nouveau repère", symbol: "perspective")
            }
            PanelRow("Placer les points de fuite…", symbol: "scope") {
                session.show360Panel = false
                session.setPerspectiveEnabled(true)
                session.perspectiveEditing = true
            }
        }
    }

    private var planeSection: some View {
        PanelSection {
            VStack(alignment: .leading, spacing: 8) {
                Text("Peindre sur un plan").foregroundStyle(.white.opacity(0.85))
                Picker("Plan", selection: Binding(get: { session.paintPlaneKind }, set: { session.setPaintPlane($0) })) {
                    ForEach(PaintPlaneKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Le pinceau et la gomme rétrécissent au loin et s'aplatissent. Le mur prend la direction regardée.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if session.paintPlane != nil {
                PanelToggle("Afficher le quadrillage", isOn: $session.paintPlaneGrid)
            }
        }
    }

    private var lookSection: some View {
        PanelSection {
            PanelRow("Demi-tour", symbol: "arrow.uturn.left.circle") {
                session.show360Panel = false
                session.turnAround()
            }
            PanelRow("Enregistrer ce regard", symbol: "bookmark") { session.saveBookmark() }
            ForEach(session.bookmarks) { bookmark in
                PanelRow(bookmark.name, symbol: "eye") {
                    session.show360Panel = false
                    session.go(to: bookmark.look)
                }
                .contextMenu {
                    Button("Renommer") {
                        newName = bookmark.name
                        renamingID = bookmark.id
                    }
                    Button("Supprimer", role: .destructive) { session.deleteBookmark(bookmark.id) }
                }
            }
        }
    }
}

/// Réglages pendant qu'on place les points de fuite sur la toile.
struct PerspectiveEditBar: View {
    @Bindable var session: CanvasSession

    var body: some View {
        HStack(spacing: 14) {
            Label("Points de fuite", systemImage: "cube.transparent").font(.callout.weight(.semibold))
            Toggle("Verticales droites", isOn: $session.perspective.keepsVerticals).fixedSize()
            Button { session.addVanishingPoint() } label: { Label("Ajouter ici", systemImage: "plus") }
            Button(role: .destructive) {
                session.deleteSelectedVanishingPoint()
            } label: {
                Label("Supprimer", systemImage: "trash")
            }
            .disabled(session.perspectiveSelection == nil)
            Button("Terminer") { session.perspectiveEditing = false }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color(white: 0.16)))
    }
}

// MARK: - Surcouches

private let axisColors: [Color] = [.orange, .cyan, .pink, .yellow, .mint, .purple]

private func axisColor(_ index: Int) -> Color { axisColors[index % axisColors.count] }

/// Grands cercles de la perspective et quadrillage du plan, recalculés quand la vue bouge.
struct Drawing360Grid: View {
    @Bindable var session: CanvasSession

    /// Ajoute une ligne de directions au tracé, coupée derrière la caméra et à la couture de la vue dépliée.
    private func add(_ points: [Vec3], to path: inout Path, _ parameters: ProjectionParameters, _ size: CGSize) {
        let wraps = parameters.morph >= 0.999
        var previous: CGPoint?
        for d in points {
            guard let q = screenPoint(of: d, parameters, size) else {
                previous = nil
                continue
            }
            if let previous, !wraps || abs(q.x - previous.x) < size.width / 2 {
                path.addLine(to: q)
            } else {
                path.move(to: q)
            }
            previous = q
        }
    }

    private func perspectivePath(axis: Vec3, _ parameters: ProjectionParameters, _ size: CGSize) -> Path {
        var path = Path()
        for normal in PerspectiveSettings.circleNormals(through: axis, count: 12) {
            add(PerspectiveSettings.circle(normal: normal, samples: 72), to: &path, parameters, size)
        }
        return path
    }

    private func planePath(_ plane: PaintPlane, _ parameters: ProjectionParameters, _ size: CGSize) -> Path {
        var path = Path()
        for line in plane.gridLines() { add(line, to: &path, parameters, size) }
        return path
    }

    var body: some View {
        GeometryReader { geo in
            let _ = session.viewRevision
            let parameters = session.view.parameters(aspect: Double(geo.size.width / max(geo.size.height, 1)))
            if (session.perspective.isEnabled && session.perspective.showsGrid) || session.perspectiveEditing {
                ForEach(Array(session.perspective.points.enumerated()), id: \.element.id) { index, point in
                    perspectivePath(axis: point.direction, parameters, geo.size)
                        .stroke(axisColor(index).opacity(0.45), lineWidth: 1)
                }
            }
            if let plane = session.paintPlane, session.paintPlaneGrid {
                planePath(plane, parameters, geo.size)
                    .stroke(Color.white.opacity(0.4), lineWidth: 1)
            }
        }
    }
}

/// Poignées des points de fuite : une pour chaque sens de l'axe, pour en atteindre au moins une où qu'on regarde.
struct VanishingHandles: View {
    @Bindable var session: CanvasSession
    private static let space = "canvas360"

    private struct Placed: Identifiable {
        let id: String
        let pointID: UUID
        let sign: Double
        let index: Int
        let position: CGPoint
    }

    private func placed(_ parameters: ProjectionParameters, _ size: CGSize) -> [Placed] {
        var out: [Placed] = []
        for (index, point) in session.perspective.points.enumerated() {
            for sign in [1.0, -1.0] {
                guard let position = screenPoint(of: point.direction * sign, parameters, size) else { continue }
                out.append(Placed(id: "\(point.id.uuidString)\(sign)", pointID: point.id, sign: sign, index: index, position: position))
            }
        }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            let _ = session.viewRevision
            let parameters = session.view.parameters(aspect: Double(geo.size.width / max(geo.size.height, 1)))
            ForEach(placed(parameters, geo.size)) { handle in
                Circle()
                    .fill(axisColor(handle.index).opacity(handle.sign > 0 ? 0.95 : 0.3))
                    .overlay(Circle().stroke(Color.white, lineWidth: session.perspectiveSelection == handle.pointID ? 3 : 1.5))
                    .frame(width: 26, height: 26)
                    .frame(width: 52, height: 52)
                    .contentShape(Circle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                            .onChanged { drag in
                                session.dragVanishingPoint(handle.pointID, sign: handle.sign, location: drag.location, size: geo.size)
                            }
                            .onEnded { _ in session.scheduleAutosave() }
                    )
                    .position(handle.position)
            }
        }
        .coordinateSpace(.named(Self.space))
    }
}
