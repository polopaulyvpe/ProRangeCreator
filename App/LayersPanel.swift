import PRCore
import PRStorage
import SwiftUI
import simd
import UIKit

/// Opérations sur la pile, toutes annulables.
extension CanvasSession {
    var activeItem: StackItem? { stack.item(activeID) }

    /// Calque actif verrouillé (lui-même ou par un groupe parent).
    var activeIsLocked: Bool { stack.isLocked(activeID) }

    /// Refuse une modification des pixels du calque actif s'il est verrouillé, avec un message.
    func refuseIfLocked() -> Bool {
        guard activeIsLocked else { return false }
        showToast("Le calque est verrouillé")
        return true
    }

    /// Enregistre un changement de structure (instantané avant / après) dans l'historique.
    private func recordStructure(_ name: String, _ body: () -> Void) {
        strokeCancelled()
        let before = stack.items
        body()
        let after = stack.items
        history.record(HistoryEntry(name: name, layerID: activeID, deltas: [], structure: (before, after)))
        refreshHistory()
        structureChanged()
    }

    /// Éléments visés par une action sur une ligne : toute la sélection multiple si la ligne en fait partie,
    /// sinon la ligne seule. Dans l'ordre de la pile (de bas en haut).
    func targets(of id: UUID) -> [UUID] {
        let chosen = layerSelection.union([activeID])
        let ids: Set<UUID> = chosen.contains(id) && chosen.count > 1 ? chosen : [id]
        return stack.items.map(\.id).filter { ids.contains($0) }
    }

    /// Glisser vers la droite : ajoute la ligne à la sélection multiple (ou l'en retire).
    func toggleInSelection(_ id: UUID) {
        guard id != activeID else { return }
        if layerSelection.contains(id) { layerSelection.remove(id) } else { layerSelection.insert(id) }
    }

    func selectAllLayers() {
        layerSelection = Set(stack.items.map(\.id)).subtracting([activeID])
    }

    func addLayer() {
        guard stack.canAddLayer else {
            fileMessage = "Limite de \(LayerStack.maxLayers) calques atteinte"
            return
        }
        var added: StackItem?
        recordStructure("Nouveau calque") { added = stack.addLayer(above: activeID) }
        layerSelection = []
        if let added { selectLayer(added.id) }
    }

    /// Duplique les calques visés ; la copie (même nom, même verrou) se place au-dessus de l'original.
    func duplicate(_ ids: [UUID]) {
        let layers = ids.filter { stack.item($0)?.layer != nil }
        guard !layers.isEmpty else { return }
        guard stack.layerCount + layers.count <= LayerStack.maxLayers else {
            fileMessage = "Limite de \(LayerStack.maxLayers) calques atteinte"
            return
        }
        var copies: [StackItem] = []
        recordStructure("Dupliquer") {
            for id in layers { if let copy = stack.duplicate(id) { copies.append(copy) } }
        }
        layerSelection = []
        if let last = copies.last { selectLayer(last.id) }
    }

    /// Supprimer : rien n'est supprimé si l'un des éléments est verrouillé (une alerte le dit).
    func requestDelete(_ ids: [UUID]) {
        let doomed = ids.flatMap { [$0] + stack.descendants(of: $0) }
        if doomed.contains(where: { stack.isLocked($0) }) {
            lockedDeleteAlert = true
            return
        }
        recordStructure("Supprimer") { for id in ids { stack.remove(id) } }
        layerSelection = []
    }

    func toggleLock(_ id: UUID) {
        guard let item = stack.item(id) else { return }
        let locking = !item.isLocked
        recordStructure(locking ? "Verrouiller le calque" : "Déverrouiller le calque") { stack.update(id) { $0.isLocked = locking } }
        showToast(locking ? "Verrouiller le calque" : "Déverrouiller le calque")
    }

    func group(_ ids: [UUID]) {
        recordStructure("Grouper") { _ = stack.group(ids) }
        layerSelection = []
    }

    /// Fusionne les calques visés en un seul, à la place du plus bas.
    func merge(_ ids: [UUID]) {
        strokeCancelled()
        applyTransform()
        guard !ids.contains(where: { stack.isLocked($0) }) else {
            showToast("Un des calques est verrouillé")
            return
        }
        guard let entry = stack.merge(ids, space: blendSpace) else { return }
        history.record(entry)
        activeID = stack.items.first { $0.layer?.id == entry.layerID }?.id ?? activeID
        layerSelection = []
        refreshHistory()
        structureChanged()
    }

    /// Fusionne tous les calques d'un groupe (le groupe reste, avec un seul calque).
    func mergeGroup(_ id: UUID) {
        merge(stack.descendants(of: id).filter { stack.item($0)?.layer != nil })
    }

    func ungroup(_ id: UUID) {
        recordStructure("Dégrouper") { stack.ungroup(id) }
    }

    func groupWithBelow(_ id: UUID) {
        var group: StackItem?
        recordStructure("Combiner vers le bas") { group = stack.groupWithBelow(id) }
        if group == nil { showToast("Rien dessous à combiner") }
    }

    func mergeActiveDown() {
        strokeCancelled()
        applyTransform()
        if let item = activeItem {
            let siblings = stack.children(of: item.parent)
            if let i = siblings.firstIndex(where: { $0.id == item.id }), i > 0,
               stack.isLocked(item.id) || stack.isLocked(siblings[i - 1].id) {
                showToast("Un des calques est verrouillé")
                return
            }
        }
        guard let entry = stack.mergeDown(activeID, space: blendSpace) else { return }
        history.record(entry)
        activeID = entry.layerID == activeID ? activeID : (stack.items.first { $0.layer?.id == entry.layerID }?.id ?? activeID)
        refreshHistory()
        structureChanged()
    }

    func flattenAll() {
        strokeCancelled()
        guard let entry = stack.flatten(space: blendSpace) else { return }
        history.record(entry)
        activeID = stack.items.first!.id
        refreshHistory()
        structureChanged()
    }

    /// Glisser-déposer d'une ligne du panneau : `destination` est l'indice de la ligne qui suivra l'élément.
    func moveRow(from source: Int, to destination: Int) {
        let rows = layerRows
        guard rows.indices.contains(source) else { return }
        let id = rows[source].id
        let above = destination > 0 ? rows[min(destination, rows.count) - 1].id : nil
        strokeCancelled()
        let before = stack.items
        guard stack.place(id, belowRow: above) else { return }
        history.record(HistoryEntry(name: "Déplacer", layerID: activeID, deltas: [], structure: (before, stack.items)))
        refreshHistory()
        structureChanged()
    }

    /// Replie ou déplie un groupe dans le panneau (pas d'historique : la toile ne change pas).
    func toggleCollapsed(_ id: UUID) {
        stack.update(id) { $0.isCollapsed.toggle() }
        layersVersion += 1
    }

    func toggleVisibility(_ id: UUID) {
        recordStructure("Visibilité") { stack.update(id) { $0.isVisible.toggle() } }
    }

    /// Ouverture du réglage d'opacité et de mode d'un calque : instantané pour une seule entrée d'historique à la fermeture.
    func beginOpacityEdit() {
        strokeCancelled()
        structureBeforeEdit = stack.items
        propertyEditID = activeID
    }

    /// Pendant le réglage : aperçu sans entrée d'historique.
    func previewOpacity(_ value: Float) {
        guard let item = activeItem, abs(item.opacity - value) > 1e-4 else { return }
        stack.update(activeID) { $0.opacity = value }
        previewPropertyChanged()
    }

    func previewBlendMode(_ mode: PRCore.BlendMode) {
        guard let item = activeItem, item.blendMode != mode else { return }
        stack.update(activeID) { $0.blendMode = mode }
        previewPropertyChanged()
    }

    private func previewPropertyChanged() {
        if canvas?.usesFastPath == true {
            // Opacité et mode du calque actif sont des uniformes du shader : rien à recomposer.
            layersVersion += 1
        } else {
            structureChanged()
        }
    }

    func commitOpacityEdit() {
        guard let before = structureBeforeEdit, let id = propertyEditID else { return }
        structureBeforeEdit = nil
        propertyEditID = nil
        let old = before.first { $0.id == id }
        let new = stack.item(id)
        guard let old, let new, old.opacity != new.opacity || old.blendMode != new.blendMode else { return }
        history.record(HistoryEntry(name: old.blendMode != new.blendMode ? "Mode de fusion" : "Opacité", layerID: id, deltas: [],
                                    structure: (before, stack.items)))
        refreshHistory()
    }

    func toggleAlphaLock() {
        recordStructure("Verrou alpha") { stack.update(activeID) { $0.alphaLock.toggle() } }
    }

    func toggleClipping() {
        recordStructure("Masque d'écrêtage") { stack.update(activeID) { $0.isClipped.toggle() } }
    }

    func toggleReference() {
        let value = activeItem?.isReference != true
        recordStructure("Référence") { stack.setReference(activeID, value) }
        showToast(value ? "Calque de référence : le remplissage suit ses contours" : "Plus de calque de référence")
    }

    func toggleMask() {
        if activeItem?.mask == nil {
            recordStructure("Ajouter un masque") { stack.addMask(activeID) }
            setPaintingMask(true)
        } else {
            recordStructure("Supprimer le masque") { stack.removeMask(activeID) }
        }
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        recordStructure("Renommer") { stack.update(id) { $0.name = trimmed } }
    }

    // MARK: - Pixels du calque

    /// Modifie tout le calque cible (limité à la sélection s'il y en a une), en une entrée d'historique.
    private func recordLayerEdit(_ name: String, _ body: (TiledLayer) -> Void) {
        strokeCancelled()
        applyTransform()
        guard !refuseIfLocked(), let target = editTarget else { return }
        target.beginOperation()
        body(target)
        if hasSelection, let selection {
            let (across, down) = TileCoord.gridSize(at: 0, baseWidth: target.width)
            var all = Set<TileCoord>()
            for y in 0..<down { for x in 0..<across { all.insert(TileCoord(x: x, y: y)) } }
            target.constrainCurrentOperation(to: selection, tiles: all)
        }
        let deltas = target.endOperation()
        guard !deltas.isEmpty else { return }
        history.record(HistoryEntry(name: name, layerID: target.id, deltas: deltas))
        refreshHistory()
        structureChanged()
    }

    func fillLayer() {
        let c = linearColor
        rememberColor()
        recordLayerEdit("Remplir le calque") { $0.fill(SIMD4<Float>(c.x, c.y, c.z, 1)) }
    }

    func clearLayer() {
        recordLayerEdit("Effacer") { $0.fill(.zero) }
    }

    /// Copier : le calque (ou la partie sélectionnée) part dans le presse-papiers de l'app.
    func copyLayer() {
        guard let item = activeItem, let source = paintingMask ? item.mask : item.layer else { return }
        copiedLayer = source.masked(by: hasSelection ? selection : nil)
        showToast(hasSelection ? "Sélection copiée" : "Calque copié")
    }

    /// Coller : le contenu copié arrive sur un nouveau calque au-dessus du calque actif.
    func pasteLayer() {
        strokeCancelled()
        applyTransform()
        guard let copied = copiedLayer, copied.width == stack.width, copied.height == stack.height else {
            showToast("Rien à coller")
            return
        }
        guard stack.canAddLayer else {
            fileMessage = "Limite de \(LayerStack.maxLayers) calques atteinte"
            return
        }
        let before = stack.items
        guard let item = stack.addLayer(above: activeID, name: "Calque collé"), let layer = item.layer else { return }
        layer.beginOperation()
        for coord in copied.storedTiles { layer.replaceTile(coord, withPixels: copied.tileFloatPixels(coord)) }
        let deltas = layer.endOperation()
        history.record(HistoryEntry(name: "Coller", layerID: layer.id, deltas: deltas, structure: (before, stack.items)))
        refreshHistory()
        layerSelection = []
        selectLayer(item.id)
        showToast("Calque collé")
    }

    /// Partager : export du calque seul (la feuille d'export propose ensuite de le partager).
    func shareLayer(_ id: UUID) {
        if id != activeID { selectLayer(id) }
        exportActiveLayerOnly = stack.item(id)?.layer != nil
        showLayers = false
        showExport = true
    }

    // MARK: - Arrière-plan

    func toggleBackgroundVisible() {
        stack.backgroundVisible.toggle()
        structureChanged()
        scheduleAutosave()
    }

    /// Couleur d'arrière-plan choisie dans le sélecteur (composantes sRGB encodées).
    func setBackground(encoded: SIMD3<Float>) {
        let linear = ColorTransfer.toLinear(simd_clamp(encoded, .zero, .one))
        guard simd_length(linear - stack.background) > 1e-4 else { return }
        stack.background = linear
        structureChanged()
        scheduleAutosave()
    }

    // MARK: - Lignes

    /// Lignes du panneau, de haut en bas, avec la profondeur d'imbrication ; les enfants des groupes repliés sont omis.
    var layerRows: [LayerRow] {
        _ = layersVersion
        var rows: [LayerRow] = []
        for item in stack.items.reversed() {
            var depth = 0
            var hidden = false
            var parent = item.parent
            while let id = parent, let p = stack.item(id) {
                depth += 1
                if p.isCollapsed { hidden = true }
                parent = p.parent
            }
            if !hidden { rows.append(LayerRow(item: item, depth: depth)) }
        }
        return rows
    }
}

struct LayerRow: Identifiable {
    let item: StackItem
    let depth: Int
    var id: UUID { item.id }
}

/// Une entrée de la liste : une ligne de calque, ou le réglage d'opacité et de mode ouvert sous elle.
private enum PanelEntry: Identifiable {
    case row(LayerRow)
    case editor(UUID)

    var id: String {
        switch self {
        case .row(let row): row.id.uuidString
        case .editor(let id): "editor-\(id.uuidString)"
        }
    }
}

extension PRCore.BlendMode {
    /// Ordre de la roue des modes : assombrir, normal, éclaircir, contraste, différence, couleur.
    static let panelOrder: [PRCore.BlendMode] = [
        .multiply, .darken, .colorBurn, .linearBurn, .darkerColor,
        .normal,
        .lighten, .screen, .colorDodge, .add, .lighterColor,
        .overlay, .softLight, .hardLight, .vividLight, .linearLight, .pinLight, .hardMix,
        .difference, .exclusion, .subtract, .divide,
        .hue, .saturation, .color, .luminosity,
    ]

    /// Abréviation affichée sur la ligne du calque.
    var shortCode: String {
        switch self {
        case .normal: "N"
        case .multiply: "M"
        case .darken: "Ob"
        case .colorBurn: "Dc"
        case .linearBurn: "Dl"
        case .darkerColor: "Cs"
        case .lighten: "É"
        case .screen: "Su"
        case .colorDodge: "Dc−"
        case .add: "A"
        case .lighterColor: "Cc"
        case .overlay: "I"
        case .softLight: "Lt"
        case .hardLight: "Lc"
        case .vividLight: "Lv"
        case .linearLight: "Ll"
        case .pinLight: "Lp"
        case .hardMix: "Mm"
        case .difference: "Di"
        case .exclusion: "Ex"
        case .subtract: "So"
        case .divide: "Dv"
        case .hue: "T"
        case .saturation: "Sa"
        case .color: "C"
        case .luminosity: "Lu"
        }
    }

    /// Pictogramme de la roue (SF Symbols).
    var symbol: String {
        switch self {
        case .normal: "square"
        case .multiply: "multiply"
        case .darken: "moon"
        case .colorBurn: "flame"
        case .linearBurn: "flame.fill"
        case .darkerColor: "circle.bottomhalf.filled"
        case .lighten: "sun.max"
        case .screen: "rectangle.on.rectangle"
        case .colorDodge: "sun.max.fill"
        case .add: "plus.square"
        case .lighterColor: "circle.tophalf.filled"
        case .overlay: "square.stack"
        case .softLight: "light.min"
        case .hardLight: "light.max"
        case .vividLight: "bolt"
        case .linearLight: "line.diagonal"
        case .pinLight: "pin"
        case .hardMix: "square.grid.2x2"
        case .difference: "minus.square"
        case .exclusion: "plusminus"
        case .subtract: "minus"
        case .divide: "divide"
        case .hue: "paintpalette"
        case .saturation: "drop.halffull"
        case .color: "paintbrush"
        case .luminosity: "sun.min"
        }
    }
}

struct LayersButton: View {
    @Bindable var session: CanvasSession

    var body: some View {
        Button("Calques", systemImage: "square.3.layers.3d") { session.showLayers = true }
            .popover(isPresented: $session.showLayers) {
                LayersPanel(session: session)
                    .frame(width: 400, height: 620)
            }
    }
}

/// Panneau des calques : lignes à vignette, glisser à gauche (verrouiller, dupliquer, supprimer), à droite (sélection
/// multiple), toucher le calque actif pour ses options, toucher la lettre du mode pour l'opacité et la roue des modes,
/// appui long pour le menu de la sélection, appui long puis glisser pour déplacer.
struct LayersPanel: View {
    @Bindable var session: CanvasSession
    @State private var blendEditor: UUID?
    @State private var renaming: UUID?
    @State private var newName = ""

    private static let rowBackground = Color(white: 0.17)

    var body: some View {
        let _ = session.layersVersion
        let rows = session.layerRows
        let entries = makeEntries(rows)
        VStack(spacing: 0) {
            header
            List {
                ForEach(entries) { entry in
                    switch entry {
                    case .row(let row):
                        rowView(row)
                    case .editor(let id):
                        if let item = session.stack.item(id) {
                            BlendEditor(session: session, item: item)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .moveDisabled(true)
                        }
                    }
                }
                .onMove { source, destination in move(entries, source, destination) }
                backgroundRow
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 10)
            budget
        }
        .background(Color(white: 0.11))
        .environment(\.colorScheme, .dark)
        .presentationCompactAdaptation(.popover)
        .onChange(of: session.activeID) { blendEditor = nil }
        .alert("Renommer", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nom", text: $newName)
            Button("OK") {
                if let id = renaming { session.rename(id, to: newName) }
                renaming = nil
            }
            Button("Annuler", role: .cancel) { renaming = nil }
        }
        .alert("Suppression de calque verrouillé", isPresented: $session.lockedDeleteAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("La suppression contient des éléments verrouillés. Déverrouille-les d'abord.")
        }
    }

    private func makeEntries(_ rows: [LayerRow]) -> [PanelEntry] {
        rows.flatMap { row -> [PanelEntry] in
            row.id == blendEditor ? [.row(row), .editor(row.id)] : [.row(row)]
        }
    }

    /// Indices de la liste (avec l'éventuel réglage ouvert) ramenés aux lignes de calques.
    private func move(_ entries: [PanelEntry], _ source: IndexSet, _ destination: Int) {
        guard let from = source.first, entries.indices.contains(from), case .row = entries[from] else { return }
        func rowIndex(_ end: Int) -> Int {
            var count = 0
            for entry in entries[..<end] {
                if case .row = entry { count += 1 }
            }
            return count
        }
        let fromRow = rowIndex(from)
        let toRow = rowIndex(min(destination, entries.count))
        blendEditor = nil
        session.moveRow(from: fromRow, to: toRow)
    }

    private var header: some View {
        let multiple = !session.layerSelection.isEmpty
        return HStack(spacing: 8) {
            Text("Calques").font(.system(size: 22, weight: .bold)).foregroundStyle(.white.opacity(0.9))
            Button {
                session.layerSelection = []
            } label: {
                Image(systemName: multiple ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(multiple ? Color.accentColor : Color(white: 0.4))
            }
            .buttonStyle(.plain)
            .disabled(!multiple)
            Spacer()
            Button { session.addLayer() } label: {
                Image(systemName: "plus").font(.system(size: 24, weight: .light)).foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .disabled(!session.stack.canAddLayer)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var budget: some View {
        let count = session.stack.layerCount
        let guaranteed = session.guaranteedLayers
        if count > guaranteed {
            Text("\(count) calques, \(guaranteed) garantis par la mémoire : fusionne des calques si l'app avertit d'un manque de mémoire.")
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
        }
    }

    // MARK: - Ligne de calque

    private func rowView(_ row: LayerRow) -> some View {
        let item = row.item
        return rowContent(item, depth: row.depth)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button { session.requestDelete(session.targets(of: item.id)) } label: { Text("Supprimer") }
                    .tint(.red)
                Button { session.duplicate(session.targets(of: item.id)) } label: { Text("Dupliquer") }
                    .tint(Color(white: 0.3))
                Button { session.toggleLock(item.id) } label: { Text(item.isLocked ? "Déverrouiller" : "Verrouiller") }
                    .tint(Color(white: 0.24))
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if item.id != session.activeID {
                    Button { session.toggleInSelection(item.id) } label: {
                        Image(systemName: session.layerSelection.contains(item.id) ? "circle" : "checkmark.circle")
                    }
                    .tint(.accentColor)
                }
            }
            .contextMenu { contextMenu(item) }
    }

    private func rowContent(_ item: StackItem, depth: Int) -> some View {
        let active = item.id == session.activeID
        let secondary = session.layerSelection.contains(item.id) && !active
        return HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 10, weight: .semibold))
                .opacity(item.isClipped ? 0.8 : 0)
                .frame(width: 12)
            if active {
                Menu {
                    options(item)
                } label: {
                    identity(item, active: true)
                }
                .menuOrder(.fixed)
                .buttonStyle(.plain)
            } else {
                identity(item, active: false)
            }
            Spacer(minLength: 4)
            if item.isGroup {
                Button { session.toggleCollapsed(item.id) } label: {
                    Image(systemName: item.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 40)
                }
                .buttonStyle(.borderless)
            }
            Button { toggleBlendEditor(item) } label: {
                Text(item.blendMode.shortCode)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(minWidth: 30, minHeight: 40)
            }
            .buttonStyle(.borderless)
            Button { session.toggleVisibility(item.id) } label: {
                Image(systemName: item.isVisible ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22))
                    .foregroundStyle(item.isVisible ? Color.white : Color(white: 0.55))
                    .frame(width: 32, height: 40)
            }
            .buttonStyle(.borderless)
        }
        .foregroundStyle(.white)
        .padding(.leading, 4 + CGFloat(depth) * 14)
        .padding(.trailing, 8)
        .frame(height: 54)
        .background(active ? Color.accentColor : secondary ? Color.accentColor.opacity(0.45) : Self.rowBackground)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture {
            session.layerSelection = []
            if !active { session.selectLayer(item.id) }
        }
    }

    /// Vignette et nom : sur le calque actif, c'est elle qui ouvre le menu des options.
    private func identity(_ item: StackItem, active: Bool) -> some View {
        HStack(spacing: 10) {
            thumbnail(item)
                .frame(width: 76, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white, lineWidth: active ? 2 : 0))
            HStack(spacing: 4) {
                if item.isLocked { Image(systemName: "lock.fill").font(.system(size: 10)) }
                if item.isReference { Image(systemName: "scope").font(.system(size: 10)) }
                if item.mask != nil { Image(systemName: "circle.lefthalf.filled").font(.system(size: 10)) }
                Text(item.name).font(.system(size: 15)).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func thumbnail(_ item: StackItem) -> some View {
        if let layer = item.layer, let image = LayerThumbnails.image(layer, revision: layer.contentVersion) {
            Image(decorative: image, scale: 1).resizable()
        } else {
            Rectangle().fill(Color(white: 0.24))
                .overlay(Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(.white.opacity(0.5)))
        }
    }

    private func toggleBlendEditor(_ item: StackItem) {
        if blendEditor == item.id {
            blendEditor = nil
            return
        }
        session.layerSelection = []
        if item.id != session.activeID { session.selectLayer(item.id) }
        blendEditor = item.id
    }

    /// Menu du calque actif (toucher sa vignette ou son nom).
    @ViewBuilder
    private func options(_ item: StackItem) -> some View {
        if item.isGroup {
            Button("Renommer") { startRenaming(item) }
            Button("Fusionner le groupe") { session.mergeGroup(item.id) }
            Button("Dégrouper") { session.ungroup(item.id) }
        } else {
            Button("Sélectionner") { session.selectLayerContent() }
            Button("Copier") { session.copyLayer() }
            Toggle("Activer le masque", isOn: Binding(get: { item.mask != nil }, set: { _ in session.toggleMask() }))
            Toggle("Masque d'écrêtage", isOn: Binding(get: { item.isClipped }, set: { _ in session.toggleClipping() }))
            Toggle("Référence", isOn: Binding(get: { item.isReference }, set: { _ in session.toggleReference() }))
            Divider()
            Button("Renommer") { startRenaming(item) }
            Button("Remplir le calque") { session.fillLayer() }
            Button("Effacer") { session.clearLayer() }
            Toggle("Verrouillage alpha", isOn: Binding(get: { item.alphaLock }, set: { _ in session.toggleAlphaLock() }))
            if item.mask != nil {
                Toggle("Peindre le masque", isOn: Binding(get: { session.paintingMask }, set: { session.setPaintingMask($0) }))
            }
            if session.copiedLayer != nil {
                Button("Coller") { session.pasteLayer() }
            }
            Divider()
            Button("Fusionner vers le bas") { session.mergeActiveDown() }
            Button("Combiner vers le bas") { session.groupWithBelow(item.id) }
        }
    }

    /// Menu de l'appui long : actions sur la sélection multiple (ou sur la ligne seule).
    @ViewBuilder
    private func contextMenu(_ item: StackItem) -> some View {
        let ids = session.targets(of: item.id)
        Button("Tout sélectionner", systemImage: "checkmark.circle") { session.selectAllLayers() }
        if ids.count > 1 {
            Button("Grouper", systemImage: "folder") { session.group(ids) }
            Button("Fusionner", systemImage: "square.3.layers.3d.down.right") { session.merge(ids) }
        }
        Button("Partager", systemImage: "square.and.arrow.up") { session.shareLayer(item.id) }
        Button("Dupliquer", systemImage: "plus.square.on.square") { session.duplicate(ids) }
        Divider()
        Button("Supprimer", systemImage: "trash", role: .destructive) { session.requestDelete(ids) }
    }

    private func startRenaming(_ item: StackItem) {
        newName = item.name
        renaming = item.id
    }

    // MARK: - Arrière-plan

    private var backgroundRow: some View {
        let background = ColorTransfer.toEncoded(session.stack.background)
        let color = Binding<Color>(
            get: { Color(.sRGB, red: Double(background.x), green: Double(background.y), blue: Double(background.z)) },
            set: { newValue in
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                UIColor(newValue).getRed(&r, green: &g, blue: &b, alpha: &a)
                session.setBackground(encoded: [Float(r), Float(g), Float(b)])
            })
        return HStack(spacing: 10) {
            ColorPicker("Couleur d'arrière-plan", selection: color, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 76, height: 38)
            Text("Couleur d'arrière-plan").font(.system(size: 15))
            Spacer()
            Button { session.toggleBackgroundVisible() } label: {
                Image(systemName: session.stack.backgroundVisible ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22))
                    .foregroundStyle(session.stack.backgroundVisible ? Color.white : Color(white: 0.55))
                    .frame(width: 32, height: 40)
            }
            .buttonStyle(.borderless)
        }
        .foregroundStyle(.white)
        .padding(.leading, 24)
        .padding(.trailing, 8)
        .frame(height: 54)
        .background(Self.rowBackground)
        .padding(.vertical, 1)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .moveDisabled(true)
    }
}

/// Réglage ouvert sous un calque : opacité, puis roue des modes de fusion (aperçu en direct, une entrée d'historique).
private struct BlendEditor: View {
    @Bindable var session: CanvasSession
    @State private var opacity: Double
    @State private var mode: PRCore.BlendMode?

    init(session: CanvasSession, item: StackItem) {
        self.session = session
        _opacity = State(initialValue: Double(item.opacity))
        _mode = State(initialValue: item.blendMode)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Opacité")
                Spacer()
                Text("\(Int((opacity * 100).rounded())) %")
            }
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.85))
            Slider(value: $opacity, in: 0...1)
                .onChange(of: opacity) { session.previewOpacity(Float(opacity)) }
            BlendWheel(selection: $mode)
                .frame(height: 230)
                .onChange(of: mode) { if let mode { session.previewBlendMode(mode) } }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.14))
        .padding(.vertical, 1)
        .onAppear { session.beginOpacityEdit() }
        .onDisappear { session.commitOpacityEdit() }
    }
}

/// Roue des modes : la liste défile derrière une bande fixe ; le mode dans la bande est celui du calque.
private struct BlendWheel: View {
    @Binding var selection: PRCore.BlendMode?
    private let rowHeight: CGFloat = 26

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(PRCore.BlendMode.panelOrder, id: \.self) { mode in
                        HStack {
                            Text(mode.label)
                            Spacer()
                            Image(systemName: mode.symbol)
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(selection == mode ? Color.white : Color(white: 0.7))
                        .padding(.horizontal, 10)
                        .frame(height: rowHeight)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { selection = mode } }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.vertical, max(0, (geometry.size.height - rowHeight) / 2), for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $selection, anchor: .center)
            .background {
                Rectangle().fill(Color.accentColor).frame(height: rowHeight)
            }
            .background(Color(white: 0.12))
        }
    }
}

/// Vignettes des calques, recalculées seulement après une opération (une par calque et par révision de l'historique).
@MainActor
enum LayerThumbnails {
    private static var cache: [UUID: (revision: Int, image: CGImage)] = [:]

    static func image(_ layer: TiledLayer, revision: Int) -> CGImage? {
        if let cached = cache[layer.id], cached.revision == revision { return cached.image }
        let w = 96, h = 48
        let pixels = layer.thumbnail(width: w, height: h)
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        let background: Float = 0.3
        for i in 0..<(w * h) {
            let p = pixels[i]
            let rgb = SIMD3<Float>(p.x, p.y, p.z) + SIMD3<Float>(repeating: background) * (1 - min(1, p.w))
            bytes[i * 4] = ColorTransfer.encode8(rgb.x)
            bytes[i * 4 + 1] = ColorTransfer.encode8(rgb.y)
            bytes[i * 4 + 2] = ColorTransfer.encode8(rgb.z)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        cache[layer.id] = (revision, image)
        return image
    }
}
