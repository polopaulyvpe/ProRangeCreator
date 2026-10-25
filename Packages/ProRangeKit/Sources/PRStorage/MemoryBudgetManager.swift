import Foundation
#if os(iOS)
import os
#endif

public enum MemoryPressure: Int, Comparable, Sendable {
    case normal
    /// On recompresse les tuiles inactives.
    case elevated
    /// On déverse tuiles et historique sur disque ; si ça ne suffit pas, on conseille de fusionner des calques.
    case critical

    public static func < (a: MemoryPressure, b: MemoryPressure) -> Bool { a.rawValue < b.rawValue }
}

/// Résultat d'un passage du gestionnaire : ce qui a été mesuré, ce qui a été fait, ce qu'il faut dire à l'utilisateur.
public struct MemoryReport: Sendable {
    public let pressure: MemoryPressure
    public let availableBytes: Int?
    public let residentBytes: Int
    public let historyBytes: Int
    public let freedBytes: Int
    /// Vrai si la pression reste critique après déversement : l'interface doit avertir et proposer de fusionner des calques.
    public let suggestMergingLayers: Bool
}

/// Garde l'app sous son budget mémoire, sans jamais planter en silence.
/// - Pression élevée : recompression en mémoire des tuiles hors de la zone de travail.
/// - Pression critique : déversement sur disque des tuiles inactives et de l'historique ancien.
/// La pression se lit sur `os_proc_available_memory` (iPadOS) ; ailleurs (tests, macOS), sur un plafond de mémoire résidente.
public final class MemoryBudgetManager {
    /// Mémoire disponible sous laquelle on passe en pression élevée.
    public var elevatedBelowAvailable = 1 << 30
    /// Mémoire disponible sous laquelle on passe en pression critique.
    public var criticalBelowAvailable = 512 << 20
    /// Plafond de mémoire résidente (pixels + historique) quand la mémoire disponible est inconnue.
    public var residentLimit = 2 << 30
    /// Entrées d'historique gardées en mémoire de part et d'autre de l'état courant.
    public var historyKeptInMemory = 20

    public let spillDirectory: URL
    private let availableBytes: @Sendable () -> Int?

    public init(spillDirectory: URL, availableBytes: @escaping @Sendable () -> Int? = MemoryBudgetManager.systemAvailableBytes) {
        self.spillDirectory = spillDirectory
        self.availableBytes = availableBytes
    }

    @Sendable
    public static func systemAvailableBytes() -> Int? {
        #if os(iOS)
        Int(os_proc_available_memory())
        #else
        nil
        #endif
    }

    public func pressure(residentBytes: Int) -> MemoryPressure {
        if let available = availableBytes() {
            if available < criticalBelowAvailable { return .critical }
            if available < elevatedBelowAvailable { return .elevated }
            return .normal
        }
        if residentBytes >= residentLimit { return .critical }
        if residentBytes >= residentLimit / 4 * 3 { return .elevated }
        return .normal
    }

    /// Mesure la pression et agit en conséquence. `workingTiles` (tuiles du calque actif en cours d'édition) restent en mémoire.
    @discardableResult
    public func relieve(layers: [TiledLayer], history: UndoRedoManager,
                        activeLayer: UUID? = nil, workingTiles: Set<TileCoord> = []) throws -> MemoryReport {
        func resident() -> Int { layers.reduce(0) { $0 + $1.residentBytes } + history.byteSize }
        let before = resident()
        let level = pressure(residentBytes: before)

        if level >= .elevated {
            for layer in layers { layer.compact(keeping: layer.id == activeLayer ? workingTiles : []) }
        }
        if level == .critical {
            for layer in layers {
                if layer.spillStore == nil {
                    layer.spillStore = try TileStore(baseURL: spillDirectory.appendingPathComponent("layers/\(layer.id.uuidString)"))
                }
                try layer.spill(keeping: layer.id == activeLayer ? workingTiles : [])
            }
            if history.spillDirectory == nil { history.spillDirectory = spillDirectory.appendingPathComponent("history") }
            try history.spill(keepingRecent: historyKeptInMemory)
        }

        let after = resident()
        let stillCritical = level == .critical && pressure(residentBytes: after) == .critical
        return MemoryReport(pressure: level, availableBytes: availableBytes(), residentBytes: after,
                            historyBytes: history.byteSize, freedBytes: max(0, before - after),
                            suggestMergingLayers: stillCritical)
    }

    /// Supprime tous les fichiers de déversement (à la fermeture du projet, après sauvegarde).
    public func purgeSpill() throws {
        if FileManager.default.fileExists(atPath: spillDirectory.path) {
            try FileManager.default.removeItem(at: spillDirectory)
        }
    }
}
