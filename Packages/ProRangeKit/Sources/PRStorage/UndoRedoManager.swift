import Foundation

/// Changement d'une tuile pendant une opération.
public struct TileDelta: Equatable, Sendable {
    public let coord: TileCoord
    public let before: TileState
    public let after: TileState
}

/// Une opération annulable : les deltas de tuiles d'un calque, en mémoire ou déversés sur disque.
public struct HistoryEntry: Sendable {
    public let name: String
    public let layerID: UUID
    /// Vide quand l'entrée est déversée (`spillURL` non nil).
    public internal(set) var deltas: [TileDelta]
    public internal(set) var spillURL: URL?

    public init(name: String, layerID: UUID, deltas: [TileDelta]) {
        self.name = name
        self.layerID = layerID
        self.deltas = deltas
        spillURL = nil
    }

    /// Octets occupés en mémoire.
    public var byteSize: Int { deltas.reduce(0) { $0 + $1.before.byteSize + $1.after.byteSize } }
    public var isSpilled: Bool { spillURL != nil }
}

/// Annuler / rétablir par deltas de tuiles compressés : exact au bit près, sans rejouer les traits.
/// Plafond réglable (défaut 1 000 pas) ; les entrées anciennes peuvent être déversées sur disque (`spill`).
public final class UndoRedoManager {
    public private(set) var entries: [HistoryEntry] = []
    /// Nombre d'entrées appliquées (les suivantes peuvent être rétablies).
    public private(set) var appliedCount = 0
    public var maxSteps: Int {
        didSet { trim() }
    }
    /// Dossier où déverser les entrées anciennes ; sans lui, `spill` ne fait rien.
    public var spillDirectory: URL?

    public init(maxSteps: Int = 1000) {
        self.maxSteps = maxSteps
    }

    deinit {
        for entry in entries { Self.deleteSpill(of: entry) }
    }

    public var canUndo: Bool { appliedCount > 0 }
    public var canRedo: Bool { appliedCount < entries.count }
    /// Octets de l'historique encore en mémoire.
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
        for dropped in entries[appliedCount...] { Self.deleteSpill(of: dropped) }
        entries.removeSubrange(appliedCount...)
        entries.append(entry)
        appliedCount = entries.count
        trim()
    }

    @discardableResult
    public func undo(in layers: [TiledLayer]) throws -> HistoryEntry? {
        guard canUndo else { return nil }
        let entry = entries[appliedCount - 1]
        guard let layer = layers.first(where: { $0.id == entry.layerID }) else { return nil }
        for delta in try deltas(of: entry) { layer.restore(delta.before, at: delta.coord) }
        appliedCount -= 1
        return entry
    }

    @discardableResult
    public func redo(in layers: [TiledLayer]) throws -> HistoryEntry? {
        guard canRedo else { return nil }
        let entry = entries[appliedCount]
        guard let layer = layers.first(where: { $0.id == entry.layerID }) else { return nil }
        for delta in try deltas(of: entry) { layer.restore(delta.after, at: delta.coord) }
        appliedCount += 1
        return entry
    }

    /// Déverse sur disque toutes les entrées sauf les `keepingRecent` plus proches de l'état courant
    /// (de part et d'autre : à annuler et à rétablir). Renvoie les octets libérés en mémoire.
    @discardableResult
    public func spill(keepingRecent: Int) throws -> Int {
        guard let directory = spillDirectory else { return 0 }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let nearby = max(0, appliedCount - keepingRecent)..<min(entries.count, appliedCount + keepingRecent)
        var freed = 0
        for i in entries.indices where !nearby.contains(i) && !entries[i].isSpilled {
            let url = directory.appendingPathComponent("\(UUID().uuidString).history")
            try DeltaCoder.encode(entries[i].deltas).write(to: url, options: .atomic)
            freed += entries[i].byteSize
            entries[i].deltas = []
            entries[i].spillURL = url
        }
        return freed
    }

    private func deltas(of entry: HistoryEntry) throws -> [TileDelta] {
        guard let url = entry.spillURL else { return entry.deltas }
        return try DeltaCoder.decode(Data(contentsOf: url))
    }

    private func trim() {
        let excess = entries.count - maxSteps
        guard excess > 0 else { return }
        let dropped = min(excess, appliedCount)
        for entry in entries.prefix(dropped) { Self.deleteSpill(of: entry) }
        entries.removeFirst(dropped)
        appliedCount -= dropped
    }

    private static func deleteSpill(of entry: HistoryEntry) {
        if let url = entry.spillURL { try? FileManager.default.removeItem(at: url) }
    }
}

/// Encodage binaire des deltas (petit-boutiste) : `[nombre]` puis, par delta, `[level][x][y][avant][après]`,
/// chaque état étant `[type 0 absent | 1 uniforme | 2 compressé][longueur][octets]`.
enum DeltaCoder {
    enum Failure: Error {
        case truncated
        case unknownKind(UInt8)
    }

    static func encode(_ deltas: [TileDelta]) -> Data {
        var out = Data()
        append(UInt32(deltas.count), to: &out)
        for delta in deltas {
            append(Int32(delta.coord.level), to: &out)
            append(Int32(delta.coord.x), to: &out)
            append(Int32(delta.coord.y), to: &out)
            append(delta.before, to: &out)
            append(delta.after, to: &out)
        }
        return out
    }

    static func decode(_ data: Data) throws -> [TileDelta] {
        var reader = Reader(bytes: [UInt8](data))
        let count = try reader.read(UInt32.self)
        var deltas: [TileDelta] = []
        deltas.reserveCapacity(Int(count))
        for _ in 0..<count {
            let level = Int(try reader.read(Int32.self))
            let x = Int(try reader.read(Int32.self))
            let y = Int(try reader.read(Int32.self))
            let before = try reader.readState()
            let after = try reader.readState()
            deltas.append(TileDelta(coord: TileCoord(level: level, x: x, y: y), before: before, after: after))
        }
        return deltas
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to out: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
    }

    private static func append(_ state: TileState, to out: inout Data) {
        switch state {
        case .absent:
            out.append(0)
            append(UInt32(0), to: &out)
        case .uniform(let d):
            out.append(1)
            append(UInt32(d.count), to: &out)
            out.append(d)
        case .packed(let d):
            out.append(2)
            append(UInt32(d.count), to: &out)
            out.append(d)
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= bytes.count else { throw Failure.truncated }
            var value: T = 0
            for i in 0..<size { value |= T(truncatingIfNeeded: bytes[offset + i]) << (8 * i) }
            offset += size
            return value
        }

        mutating func readState() throws -> TileState {
            guard offset < bytes.count else { throw Failure.truncated }
            let kind = bytes[offset]
            offset += 1
            let length = Int(try read(UInt32.self))
            guard offset + length <= bytes.count else { throw Failure.truncated }
            let payload = Data(bytes[offset..<(offset + length)])
            offset += length
            switch kind {
            case 0: return .absent
            case 1: return .uniform(payload)
            case 2: return .packed(payload)
            default: throw Failure.unknownKind(kind)
            }
        }
    }
}
