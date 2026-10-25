import Foundation

/// Gestionnaire undo/redo basé sur checkpoints + replay journal.
/// - Checkpoints réguliers (tous les N ops ou sur demande) = points de restauration rapides.
/// - Replay depuis le dernier checkpoint pour undo granulaire.
/// - Redo stack pour ré-appliquer les opérations annulées.
@MainActor
public final class UndoRedoManager: ObservableObject, Sendable {
    public let package: ProjectPackage
    public let journal: OperationJournal
    public let tileStore: TileStore

    // Configuration
    public var checkpointInterval: Int = 50  // Checkpoint auto toutes les N opérations
    public var maxRedoStack: Int = 100

    @Published public private(set) var canUndo: Bool = false
    @Published public private(set) var canRedo: Bool = false
    @Published public private(set) var currentOperationIndex: Int = 0

    private var redoStack: [OperationRecord] = []
    private var lastCheckpointIndex: Int = 0
    private var operationsSinceCheckpoint: Int = 0

    private let replayQueue = DispatchQueue(label: "com.prrange.undoredo.replay", qos: .userInitiated)

    public init(package: ProjectPackage) {
        self.package = package
        self.journal = package.journal
        self.tileStore = package.tileStore
        self.currentOperationIndex = journal.currentIndex
        self.lastCheckpointIndex = journal.currentIndex
        updateCanUndoRedo()
    }

    // MARK: - API publique

    /// Enregistre une opération de pinceau.
    public func recordStroke(
        centers: [Vec3],
        radius: Double,
        hardness: Double,
        color: SIMD4<Float>,
        spacing: Double,
        screenSpace: Bool,
        apply: @escaping (StrokeOp) async throws -> Void
    ) async throws {
        try await recordOperation { [journal] in
            try journal.appendStroke(
                centers: centers, radius: radius, hardness: hardness,
                color: color, spacing: spacing, screenSpace: screenSpace
            )
        } apply: { op in
            try await apply(op)
        }
    }

    /// Enregistre une opération de gomme.
    public func recordErase(
        centers: [Vec3],
        radius: Double,
        hardness: Double,
        spacing: Double,
        screenSpace: Bool,
        apply: @escaping (EraseOp) async throws -> Void
    ) async throws {
        try await recordOperation { [journal] in
            try journal.appendErase(
                centers: centers, radius: radius, hardness: hardness,
                spacing: spacing, screenSpace: screenSpace
            )
        } apply: { op in
            try await apply(op)
        }
    }

    /// Enregistre une opération de remplissage.
    public func recordFill(
        start: Vec3,
        tolerance: Double,
        color: SIMD4<Float>,
        apply: @escaping (FillOp) async throws -> Void
    ) async throws {
        try await recordOperation { [journal] in
            try journal.appendFill(start: start, tolerance: tolerance, color: color)
        } apply: { op in
            try await apply(op)
        }
    }

    /// Enregistre une transformation.
    public func recordTransform(
        matrix: [[Double]],
        affectedTiles: [TileCoord]?,
        apply: @escaping (TransformOp) async throws -> Void
    ) async throws {
        try await recordOperation { [journal] in
            try journal.appendTransform(matrix: matrix, affectedTiles: affectedTiles)
        } apply: { op in
            try await apply(op)
        }
    }

    /// Annule la dernière opération (ou revient au checkpoint précédent).
    public func undo() async throws {
        guard canUndo else { return }

        // Sauvegarder l'état courant pour redo
        let currentIndex = currentOperationIndex
        let checkpoint = try package.createCheckpoint(name: "undo-\(currentIndex)")
        redoStack.append(OperationRecord(
            index: currentIndex,
            checkpointURL: checkpoint,
            type: .checkpoint
        ))
        if redoStack.count > maxRedoStack { redoStack.removeFirst() }

        // Revenir au checkpoint précédent
        let checkpoints = package.listCheckpoints()
        guard let previous = checkpoints.first(where: { $0.journalIndex < currentIndex }) else {
            // Pas de checkpoint précédent : rejouer depuis le début sans la dernière op
            try await replayToIndex(currentIndex - 1)
            return
        }

        try await restoreToCheckpoint(previous)
        updateCanUndoRedo()
    }

    /// Rétablit la dernière opération annulée.
    public func redo() async throws {
        guard canRedo, let record = redoStack.popLast() else { return }

        // Créer un checkpoint de l'état actuel avant redo
        let currentIndex = currentOperationIndex
        let checkpoint = try package.createCheckpoint(name: "redo-\(currentIndex)")

        // Rejouer depuis le checkpoint enregistré
        try await replayFromCheckpoint(record.checkpointURL, toIndex: record.index)

        // Sauvegarder l'ancien checkpoint pour un éventuel re-undo
        redoStack.append(OperationRecord(
            index: currentIndex,
            checkpointURL: checkpoint,
            type: .checkpoint
        ))
        updateCanUndoRedo()
    }

    /// Force un checkpoint manuel.
    public func createCheckpoint(name: String? = nil) throws -> URL {
        let url = try package.createCheckpoint(name: name)
        lastCheckpointIndex = journal.currentIndex
        operationsSinceCheckpoint = 0
        updateCanUndoRedo()
        return url
    }

    /// Rejoue tout le journal depuis le début (pour rechargement projet).
    public func replayAll(apply: @escaping (Operation) async throws -> Void) async throws {
        try await replayFromIndex(0, apply: apply)
    }

    // MARK: - Implémentation privée

    private func recordOperation(
        write: () throws -> Void,
        apply: @escaping (Operation) async throws -> Void
    ) async throws {
        // Écrire dans le journal
        try write()

        // Appliquer l'opération
        let op = try journal.operation(at: journal.currentIndex - 1)!
        try await apply(op)

        // Vider la pile redo (nouvelle branche d'historique)
        redoStack.removeAll()

        currentOperationIndex = journal.currentIndex
        operationsSinceCheckpoint += 1

        // Checkpoint automatique ?
        if operationsSinceCheckpoint >= checkpointInterval {
            _ = try createCheckpoint(name: "auto-\(currentOperationIndex)")
        }

        updateCanUndoRedo()
    }

    /// Rejoue les opérations depuis `fromIndex` (inclusif) jusqu'à la fin.
    private func replayFromIndex(_ fromIndex: Int, apply: @escaping (Operation) async throws -> Void) async throws {
        let checkpoints = package.listCheckpoints()
        let startCheckpoint = checkpoints.last { $0.journalIndex <= fromIndex }

        if let cp = startCheckpoint {
            // Restaurer le checkpoint
            try await restoreToCheckpoint(cp, apply: apply)
            // Rejouer depuis le checkpoint
            try await replayFromCheckpoint(cp.checkpointURL!, toIndex: journal.currentIndex, apply: apply)
        } else {
            // Rejouer depuis le début
            try await journal.replay(fromIndex: fromIndex) { op in
                try await apply(op)
            }
            currentOperationIndex = journal.currentIndex
        }
    }

    private func replayFromCheckpoint(_ checkpointURL: URL, toIndex: Int, apply: @escaping (Operation) async throws -> Void) async throws {
        let cpData = try Data(contentsOf: checkpointURL)
        let checkpoint = try JSONDecoder().decode(ProjectPackage.Checkpoint.self, from: cpData)

        try await journal.replay(fromIndex: checkpoint.journalIndex) { op in
            try await apply(op)
        }
        currentOperationIndex = journal.currentIndex
    }

    /// Rejoue jusqu'à un index donné (exclusif).
    private func replayToIndex(_ toIndex: Int) async throws {
        // Trouver le checkpoint le plus proche avant toIndex
        let checkpoints = package.listCheckpoints()
        let startCheckpoint = checkpoints.last { $0.journalIndex <= toIndex }

        if let cp = startCheckpoint {
            try await restoreToCheckpoint(cp)
            try await journal.replay(fromIndex: cp.journalIndex) { [weak self] op in
                guard let self else { return }
                // Pour undo simple, on ne ré-applique pas vraiment ici
                // (l'application réelle se fait via le TileStore/Canvas)
            }
        } else {
            // Pas de checkpoint : rejouer depuis 0
            try await journal.replay(fromIndex: 0) { _ in }
        }
        currentOperationIndex = toIndex
        updateCanUndoRedo()
    }

    private func restoreToCheckpoint(_ checkpoint: ProjectPackage.Checkpoint, apply: ((Operation) async throws -> Void)? = nil) async throws {
        // 1. Tronquer le journal
        try journal.truncate(to: checkpoint.journalIndex)

        // 2. Recharger les tuiles affectées depuis le disque (elles sont déjà à jour dans le checkpoint)
        // Dans une vraie implémentation, on restaurerait les tuiles depuis un snapshot
        // Ici on se contente de marquer les tuiles comme clean
        tileStore.markClean(modifiedTiles: checkpoint.modifiedTiles)

        currentOperationIndex = checkpoint.journalIndex
        lastCheckpointIndex = checkpoint.journalIndex
        operationsSinceCheckpoint = 0

        // 3. Rejouer si un handler est fourni
        if let apply {
            try await journal.replay(fromIndex: checkpoint.journalIndex) { op in
                try await apply(op)
            }
        }
    }

    private func updateCanUndoRedo() {
        canUndo = currentOperationIndex > 0
        canRedo = !redoStack.isEmpty
    }

    // MARK: - Types internes

    private struct OperationRecord {
        let index: Int
        let checkpointURL: URL
        let type: RecordType
    }

    private enum RecordType {
        case checkpoint
        case operation
    }
}

// MARK: - Helpers pour Vec3 (déjà dans PRCore mais redéclaré ici pour l'indépendance)

public typealias Vec3 = SIMD3<Double>

public struct TileCoord: Hashable, Sendable, Codable {
    public let level: Int
    public let x: Int
    public let y: Int

    public init(level: Int, x: Int, y: Int) {
        self.level = level
        self.x = x
        self.y = y
    }
}

// Extension pour décoder les checkpoints depuis JSON
extension ProjectPackage.Checkpoint {
    var checkpointURL: URL? { nil } // Sera défini par UndoRedoManager
}