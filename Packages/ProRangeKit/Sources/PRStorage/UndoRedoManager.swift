import Foundation

/// Changement d'une tuile pendant une opération.
public struct TileDelta: Equatable, Sendable {
    public let coord: TileCoord
    public let before: TileState
    public let after: TileState
}

/// Une opération annulable : les deltas de tuiles d'un calque.
public struct HistoryEntry: Sendable {
    public let name: String
    public let layerID: UUID
    public let deltas: [TileDelta]

    public var byteSize: Int { deltas.reduce(0) { $0 + $1.before.byteSize + $1.after.byteSize } }
}

/// Annuler / rétablir par deltas de tuiles compressés : exact au bit près, sans rejouer les traits.
/// Plafond réglable (défaut 1 000 pas) ; le débordement sur disque viendra avec le gestionnaire de mémoire.
public final class UndoRedoManager {
    public private(set) var entries: [HistoryEntry] = []
    /// Nombre d'entrées appliquées (les suivantes peuvent être rétablies).
    public private(set) var appliedCount = 0
    public var maxSteps: Int {
        didSet { trim() }
    }

    public init(maxSteps: Int = 1000) {
        self.maxSteps = maxSteps
    }

    public var canUndo: Bool { appliedCount > 0 }
    public var canRedo: Bool { appliedCount < entries.count }
    public var byteSize: Int { entries.reduce(0) { $0 + $1.byteSize } }

    /// Exécute `body` sur `layer` en enregistrant les tuiles touchées. Une opération sans effet n'est pas enregistrée.
    @discardableResult
    public func perform(_ name: String, on layer: TiledLayer, _ body: () -> Void) -> HistoryEntry? {
        layer.beginOperation()
        body()
        let deltas = layer.endOperation()
        guard !deltas.isEmpty else { return nil }
        let entry = HistoryEntry(name: name, layerID: layer.id, deltas: deltas)
        record(entry)
        return entry
    }

    public func record(_ entry: HistoryEntry) {
        entries.removeSubrange(appliedCount...)
        entries.append(entry)
        appliedCount = entries.count
        trim()
    }

    @discardableResult
    public func undo(in layers: [TiledLayer]) -> HistoryEntry? {
        guard canUndo else { return nil }
        let entry = entries[appliedCount - 1]
        guard let layer = layers.first(where: { $0.id == entry.layerID }) else { return nil }
        for delta in entry.deltas { layer.restore(delta.before, at: delta.coord) }
        appliedCount -= 1
        return entry
    }

    @discardableResult
    public func redo(in layers: [TiledLayer]) -> HistoryEntry? {
        guard canRedo else { return nil }
        let entry = entries[appliedCount]
        guard let layer = layers.first(where: { $0.id == entry.layerID }) else { return nil }
        for delta in entry.deltas { layer.restore(delta.after, at: delta.coord) }
        appliedCount += 1
        return entry
    }

    private func trim() {
        let excess = entries.count - maxSteps
        guard excess > 0 else { return }
        let dropped = min(excess, appliedCount)
        entries.removeFirst(dropped)
        appliedCount -= dropped
    }
}
