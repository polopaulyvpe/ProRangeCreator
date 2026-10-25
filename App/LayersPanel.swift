import PRCore
import PRStorage
import SwiftUI

/// Opérations sur la pile, toutes annulables.
extension CanvasSession {
    var activeItem: StackItem? { stack.item(activeID) }

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

    func addLayer() {
        guard stack.canAddLayer else {
            fileMessage = "Limite de \(LayerStack.maxLayers) calques atteinte"
            return
        }
        var added: StackItem?
        recordStructure("Nouveau calque") { added = stack.addLayer(above: activeID) }
        if let added { selectLayer(added.id) }
    }

    func duplicateActive() {
        var copy: StackItem?
        recordStructure("Dupliquer") { copy = stack.duplicate(activeID) }
        if let copy { selectLayer(copy.id) }
    }

    func deleteActive() {
        recordStructure("Supprimer") { stack.remove(activeID) }
    }

    func moveActive(by step: Int) {
        recordStructure(step > 0 ? "Monter" : "Descendre") { stack.move(activeID, by: step) }
    }

    func groupActiveWithBelow() {
        var group: StackItem?
        recordStructure("Grouper") { group = stack.groupWithBelow(activeID) }
        if let group { selectLayer(group.id) }
    }

    func ungroupActive() {
        recordStructure("Dégrouper") { stack.ungroup(activeID) }
    }

    func mergeActiveDown() {
        strokeCancelled()
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

    func toggleVisibility(_ id: UUID) {
        recordStructure("Visibilité") { stack.update(id) { $0.isVisible.toggle() } }
    }

    func setBlendMode(_ mode: BlendMode) {
        recordStructure("Mode de fusion") { stack.update(activeID) { $0.blendMode = mode } }
    }

    /// Début du glissé du curseur d'opacité : on mémorise la structure d'avant pour une seule entrée d'historique.
    func beginOpacityEdit() {
        strokeCancelled()
        structureBeforeEdit = stack.items
    }

    /// Pendant le glissé : aperçu sans entrée d'historique.
    func previewOpacity(_ value: Float) {
        guard let item = activeItem, abs(item.opacity - value) > 1e-4 else { return }
        stack.update(activeID) { $0.opacity = value }
        if canvas?.usesFastPath == true {
            // L'opacité du calque actif est un uniforme du shader : rien à recomposer.
            layersVersion += 1
        } else {
            structureChanged()
        }
    }

    func commitOpacityEdit() {
        guard let before = structureBeforeEdit else { return }
        structureBeforeEdit = nil
        history.record(HistoryEntry(name: "Opacité", layerID: activeID, deltas: [], structure: (before, stack.items)))
        refreshHistory()
    }

    func toggleAlphaLock() {
        recordStructure("Verrou alpha") { stack.update(activeID) { $0.alphaLock.toggle() } }
    }

    func toggleClipping() {
        recordStructure("Masque d'écrêtage") { stack.update(activeID) { $0.isClipped.toggle() } }
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
        recordStructure("Renommer") { stack.update(id) { $0.name = name } }
    }

    /// Lignes du panneau, de haut en bas, avec la profondeur d'imbrication.
    var layerRows: [LayerRow] {
        _ = layersVersion
        func depth(_ item: StackItem) -> Int {
            var d = 0
            var parent = item.parent
            while let id = parent {
                d += 1
                parent = stack.item(id)?.parent
            }
            return d
        }
        return stack.items.reversed().map { LayerRow(item: $0, depth: depth($0)) }
    }
}

struct LayerRow: Identifiable {
    let item: StackItem
    let depth: Int
    var id: UUID { item.id }
}

struct LayersButton: View {
    @Bindable var session: CanvasSession

    var body: some View {
        Button("Calques", systemImage: "square.3.layers.3d") { session.showLayers = true }
            .popover(isPresented: $session.showLayers) {
                LayersPanel(session: session)
                    .frame(width: 360, height: 620)
            }
    }
}

struct LayersPanel: View {
    @Bindable var session: CanvasSession
    @State private var opacity: Double = 1
    @State private var renaming: UUID?
    @State private var newName = ""

    var body: some View {
        let _ = session.layersVersion
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Calques").font(.headline)
                Spacer()
                Button("Nouveau calque", systemImage: "plus") { session.addLayer() }
                    .labelStyle(.iconOnly)
                    .disabled(!session.stack.canAddLayer)
            }
            budget

            List {
                ForEach(session.layerRows) { row in
                    layerRow(row.item, depth: row.depth)
                }
            }
            .listStyle(.plain)

            if let item = session.activeItem {
                properties(item)
            }
        }
        .padding(14)
        .onAppear { opacity = Double(session.activeItem?.opacity ?? 1) }
        .onChange(of: session.activeID) { opacity = Double(session.activeItem?.opacity ?? 1) }
        .alert("Renommer", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nom", text: $newName)
            Button("OK") {
                if let id = renaming { session.rename(id, to: newName) }
                renaming = nil
            }
            Button("Annuler", role: .cancel) { renaming = nil }
        }
    }

    private var budget: some View {
        let count = session.stack.layerCount
        let guaranteed = session.guaranteedLayers
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(count) / \(LayerStack.maxLayers) calques · \(guaranteed) garantis par la mémoire")
                .font(.caption)
                .foregroundStyle(count > guaranteed ? .orange : .secondary)
            if count > guaranteed {
                Text("Au-delà du nombre garanti, ça tient tant que les calques restent en partie vides. Fusionne des calques si l'app avertit d'un manque de mémoire.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func layerRow(_ item: StackItem, depth: Int) -> some View {
        let selected = item.id == session.activeID
        return HStack(spacing: 8) {
            Button {
                session.toggleVisibility(item.id)
            } label: {
                Image(systemName: item.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(item.isVisible ? .primary : .secondary)
            }
            .buttonStyle(.borderless)

            if item.isClipped { Image(systemName: "arrow.turn.left.down").font(.caption) }
            Image(systemName: item.isGroup ? "folder" : "square")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                HStack(spacing: 6) {
                    if item.blendMode != .normal { Text(item.blendMode.label) }
                    if item.opacity < 1 { Text("\(Int(item.opacity * 100)) %") }
                    if item.alphaLock { Image(systemName: "lock") }
                    if item.mask != nil { Image(systemName: "circle.lefthalf.filled") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.leading, CGFloat(depth) * 16)
        .contentShape(Rectangle())
        .onTapGesture { session.selectLayer(item.id) }
        .onLongPressGesture {
            newName = item.name
            renaming = item.id
        }
        .listRowBackground(selected ? Color.accentColor.opacity(0.25) : Color.clear)
    }

    private func properties(_ item: StackItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Text("Opacité \(Int(opacity * 100)) %").font(.caption)
                Slider(value: $opacity, in: 0...1, onEditingChanged: { editing in
                    if editing { session.beginOpacityEdit() } else { session.commitOpacityEdit() }
                })
                .onChange(of: opacity) { session.previewOpacity(Float(opacity)) }
            }
            Picker("Mode", selection: Binding(get: { item.blendMode }, set: { session.setBlendMode($0) })) {
                ForEach(BlendMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)

            if !item.isGroup {
                HStack {
                    Toggle("Verrou alpha", isOn: Binding(get: { item.alphaLock }, set: { _ in session.toggleAlphaLock() }))
                    Toggle("Écrêtage", isOn: Binding(get: { item.isClipped }, set: { _ in session.toggleClipping() }))
                }
                .font(.caption)
                HStack {
                    Button(item.mask == nil ? "Ajouter un masque" : "Supprimer le masque") { session.toggleMask() }
                    if item.mask != nil {
                        Toggle("Peindre le masque", isOn: Binding(get: { session.paintingMask }, set: { session.setPaintingMask($0) }))
                    }
                }
                .font(.caption)
            }

            HStack(spacing: 14) {
                Button("Monter", systemImage: "arrow.up") { session.moveActive(by: 1) }
                Button("Descendre", systemImage: "arrow.down") { session.moveActive(by: -1) }
                if !item.isGroup {
                    Button("Dupliquer", systemImage: "plus.square.on.square") { session.duplicateActive() }
                    Button("Fusionner vers le bas", systemImage: "arrow.down.to.line") { session.mergeActiveDown() }
                }
                Button("Supprimer", systemImage: "trash", role: .destructive) { session.deleteActive() }
            }
            .labelStyle(.iconOnly)

            HStack(spacing: 14) {
                Button("Grouper avec dessous") { session.groupActiveWithBelow() }
                if item.isGroup { Button("Dégrouper") { session.ungroupActive() } }
                Spacer()
                Button("Aplatir tout") { session.flattenAll() }
            }
            .font(.caption)
        }
    }
}
