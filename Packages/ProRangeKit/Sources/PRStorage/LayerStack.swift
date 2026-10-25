import Foundation
import PRCore

/// Un élément de la pile : un calque de pixels ou un groupe.
/// Valeur (struct) qui référence les calques : une copie de `[StackItem]` est un instantané de structure peu coûteux,
/// ce qui rend annulables l'ajout, la suppression, le déplacement et les changements de propriétés.
public struct StackItem: Identifiable {
    public enum Kind {
        case layer(TiledLayer)
        case group
    }

    public let id: UUID
    public var kind: Kind
    public var name: String
    public var opacity: Float = 1
    public var isVisible = true
    public var blendMode: BlendMode = .normal
    /// Le pinceau ne modifie que la couleur, pas la transparence existante.
    public var alphaLock = false
    /// Masque d'écrêtage : l'élément n'apparaît que là où l'élément non écrêté juste dessous est opaque.
    public var isClipped = false
    /// Masque de calque (blanc = visible, noir = caché), lu sur le canal rouge.
    public var mask: TiledLayer?
    /// Groupe parent (`nil` = racine).
    public var parent: UUID?

    public init(id: UUID = UUID(), kind: Kind, name: String, parent: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.parent = parent
    }

    public var layer: TiledLayer? {
        if case .layer(let l) = kind { return l }
        return nil
    }

    public var isGroup: Bool {
        if case .group = kind { return true }
        return false
    }
}

/// Pile de calques : ordre de bas en haut ; les enfants d'un groupe sont juste sous lui, contigus.
public final class LayerStack: HistoryTarget {
    /// Plafond du cahier des charges.
    public static let maxLayers = 50

    public let width: Int
    public let height: Int
    public let format: LayerPixelFormat
    public private(set) var items: [StackItem]

    public init(width: Int, height: Int, format: LayerPixelFormat = .rgba16Float, items: [StackItem]? = nil) {
        self.width = width
        self.height = height
        self.format = format
        self.items = items ?? [StackItem(kind: .layer(TiledLayer(name: "Calque 1", width: width, height: height, format: format)),
                                         name: "Calque 1")]
    }

    // MARK: - Lecture

    public var layerCount: Int { items.filter { !$0.isGroup }.count }
    public var canAddLayer: Bool { layerCount < Self.maxLayers }

    public func index(of id: UUID) -> Int? { items.firstIndex { $0.id == id } }
    public func item(_ id: UUID) -> StackItem? { index(of: id).map { items[$0] } }

    /// Enfants directs d'un groupe (ou de la racine), de bas en haut.
    public func children(of parent: UUID?) -> [StackItem] { items.filter { $0.parent == parent } }

    /// Tous les calques de pixels et leurs masques (pour l'historique, la sauvegarde, la mémoire).
    public var allTiledLayers: [TiledLayer] {
        items.flatMap { item -> [TiledLayer] in [item.layer, item.mask].compactMap { $0 } }
    }

    public func tiledLayer(id: UUID) -> TiledLayer? { allTiledLayers.first { $0.id == id } }

    /// Calques garantis dans le pire cas pour la mémoire disponible (voir `MemoryBudget`).
    public func guaranteedLayers(availableBytes: Int) -> Int {
        MemoryBudget(availableBytes: availableBytes)
            .guaranteedLayers(CanvasResolution(width: width), format == .rgba16Float ? .rgba16Float : .rgba8)
    }

    // MARK: - Structure (chaque opération renvoie l'instantané d'avant, pour l'historique)

    public func restoreStructure(_ snapshot: [StackItem]) {
        items = snapshot
    }

    /// Ajoute un calque vide au-dessus de `above` (ou en haut de la pile), dans le même groupe.
    @discardableResult
    public func addLayer(above: UUID? = nil, name: String? = nil) -> StackItem? {
        guard canAddLayer else { return nil }
        let title = name ?? "Calque \(layerCount + 1)"
        let layer = TiledLayer(name: title, width: width, height: height, format: format)
        var item = StackItem(kind: .layer(layer), name: title)
        if let above, let i = index(of: above) {
            item.parent = items[i].parent
            items.insert(item, at: i + 1)
        } else {
            items.append(item)
        }
        return item
    }

    @discardableResult
    public func duplicate(_ id: UUID) -> StackItem? {
        guard let i = index(of: id), let layer = items[i].layer, canAddLayer else { return nil }
        var copy = items[i]
        let name = "\(copy.name) copie"
        copy = StackItem(kind: .layer(layer.duplicate(name: name)), name: name, parent: items[i].parent)
        copy.opacity = items[i].opacity
        copy.isVisible = items[i].isVisible
        copy.blendMode = items[i].blendMode
        copy.alphaLock = items[i].alphaLock
        copy.isClipped = items[i].isClipped
        copy.mask = items[i].mask?.duplicate()
        items.insert(copy, at: i + 1)
        return copy
    }

    /// Supprime un élément (un groupe emporte ses enfants). Refuse de supprimer le dernier calque.
    public func remove(_ id: UUID) {
        let doomed = Set([id] + descendants(of: id))
        let remaining = items.filter { !doomed.contains($0.id) }
        guard remaining.contains(where: { !$0.isGroup }) else { return }
        items = remaining
    }

    /// Déplace un élément d'un cran vers le haut (+1) ou le bas (−1) parmi ses frères, avec ses enfants.
    public func move(_ id: UUID, by step: Int) {
        guard let item = item(id) else { return }
        let siblings = children(of: item.parent)
        guard let position = siblings.firstIndex(where: { $0.id == id }) else { return }
        let target = position + step
        guard siblings.indices.contains(target) else { return }
        let block = itemsBlock(of: id)
        let other = itemsBlock(of: siblings[target].id)
        var rest = items.filter { element in !block.contains { $0.id == element.id } }
        let blockItems = items.filter { element in block.contains { $0.id == element.id } }
        if step > 0 {
            let anchor = rest.lastIndex { element in other.contains { $0.id == element.id } }!
            rest.insert(contentsOf: blockItems, at: anchor + 1)
        } else {
            let anchor = rest.firstIndex { element in other.contains { $0.id == element.id } }!
            rest.insert(contentsOf: blockItems, at: anchor)
        }
        items = rest
    }

    /// Modifie les propriétés d'un élément.
    public func update(_ id: UUID, _ change: (inout StackItem) -> Void) {
        guard let i = index(of: id) else { return }
        change(&items[i])
    }

    /// Met l'élément et celui juste dessous (frères) dans un nouveau groupe.
    @discardableResult
    public func groupWithBelow(_ id: UUID) -> StackItem? {
        guard let item = item(id) else { return nil }
        let siblings = children(of: item.parent)
        guard let position = siblings.firstIndex(where: { $0.id == id }), position > 0 else { return nil }
        let below = siblings[position - 1]
        let group = StackItem(kind: .group, name: "Groupe", parent: item.parent)
        for member in [below.id, id] { update(member) { $0.parent = group.id } }
        // Le groupe se place juste au-dessus du bloc de son membre le plus haut.
        let topIndex = items.lastIndex { element in itemsBlock(of: id).contains { $0.id == element.id } }!
        items.insert(group, at: topIndex + 1)
        return group
    }

    /// Dissout un groupe : ses enfants rejoignent le parent du groupe.
    public func ungroup(_ id: UUID) {
        guard let group = item(id), group.isGroup else { return }
        for child in children(of: id) { update(child.id) { $0.parent = group.parent } }
        items.removeAll { $0.id == id }
    }

    public func addMask(_ id: UUID) {
        update(id) { item in
            guard item.mask == nil else { return }
            let mask = TiledLayer(name: "Masque", width: width, height: height, format: format)
            mask.fill([1, 1, 1, 1])
            item.mask = mask
        }
    }

    public func removeMask(_ id: UUID) {
        update(id) { $0.mask = nil }
    }

    // MARK: - Aide

    /// Descendants d'un groupe (tous niveaux).
    public func descendants(of id: UUID) -> [UUID] {
        children(of: id).flatMap { [$0.id] + descendants(of: $0.id) }
    }

    /// L'élément et ses descendants, dans l'ordre de la pile.
    private func itemsBlock(of id: UUID) -> [StackItem] {
        let ids = Set([id] + descendants(of: id))
        return items.filter { ids.contains($0.id) }
    }
}
