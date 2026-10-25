import Foundation
import PRCore
import PRStorage
import XCTest

final class SpillTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("prspill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSpilledTilesReadBackAndKeepPainting() throws {
        var rng = SplitMix64(state: 11)
        let layer = TiledLayer(name: "t", width: 2048, height: 1024)
        layer.spillStore = try TileStore(baseURL: directory.appendingPathComponent("layer"))
        for _ in 0..<12 { layer.stamp(randomDab(&rng)) }
        let before = dump(layer)

        let freed = try layer.spill()
        XCTAssertGreaterThan(freed, 0)
        XCTAssertGreaterThan(layer.spilledTileCount, 0)
        XCTAssertLessThan(layer.residentBytes, 1024, "il ne reste que des tuiles uniformes en mémoire")
        XCTAssertEqual(dump(layer), before)

        // Peindre sur des tuiles déversées les recharge et supprime leurs fichiers.
        let history = UndoRedoManager()
        history.perform("après déversement", on: layer) {
            for _ in 0..<6 { layer.stamp(randomDab(&rng)) }
        }
        let painted = dump(layer)
        try history.undo(in: [layer])
        XCTAssertEqual(dump(layer), before)
        try history.redo(in: [layer])
        XCTAssertEqual(dump(layer), painted)

        layer.unspillAll()
        XCTAssertEqual(layer.spilledTileCount, 0)
        XCTAssertTrue(layer.spillStore!.list(level: 0).isEmpty, "plus aucun fichier de déversement")
        XCTAssertEqual(dump(layer), painted)
    }

    func testSpilledLayerSavesNormally() throws {
        var rng = SplitMix64(state: 5)
        let layer = TiledLayer(name: "t", width: 1024, height: 512)
        layer.spillStore = try TileStore(baseURL: directory.appendingPathComponent("layer"))
        for _ in 0..<5 { layer.stamp(randomDab(&rng)) }
        try layer.spill()
        let url = directory.appendingPathComponent("P.prrange")
        try ProjectPackage.save(layers: [layer], to: url)
        XCTAssertEqual(dump(try ProjectPackage.load(from: url).layers[0]), dump(layer))
    }

    func testHistorySpillKeepsUndoBitExact() throws {
        var rng = SplitMix64(state: 21)
        let layer = TiledLayer(name: "t", width: 2048, height: 1024)
        let history = UndoRedoManager()
        history.spillDirectory = directory.appendingPathComponent("history")
        var snapshots = [dump(layer)]
        for i in 0..<10 {
            history.perform("\(i)", on: layer) { for _ in 0..<3 { layer.stamp(randomDab(&rng)) } }
            snapshots.append(dump(layer))
        }
        let inMemory = history.byteSize
        let freed = try history.spill(keepingRecent: 2)
        XCTAssertGreaterThan(freed, 0)
        XCTAssertLessThan(history.byteSize, inMemory)
        XCTAssertEqual(history.entries.filter(\.isSpilled).count, 8)

        for i in stride(from: 9, through: 0, by: -1) {
            try history.undo(in: [layer])
            XCTAssertEqual(dump(layer), snapshots[i])
        }
        for i in 1...10 {
            try history.redo(in: [layer])
            XCTAssertEqual(dump(layer), snapshots[i])
        }
    }

    func testDroppedHistoryEntriesDeleteTheirFiles() throws {
        let layer = TiledLayer(name: "t", width: 1024, height: 512)
        let history = UndoRedoManager(maxSteps: 3)
        let historyDir = directory.appendingPathComponent("history")
        history.spillDirectory = historyDir
        for i in 0..<3 { history.perform("\(i)", on: layer) { layer.fill([Float(i + 1) / 10, 0, 0, 1]) } }
        try history.spill(keepingRecent: 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: historyDir.path).count, 3)
        for i in 3..<6 { history.perform("\(i)", on: layer) { layer.fill([Float(i + 1) / 10, 0, 0, 1]) } }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: historyDir.path).count, 0)
    }
}

final class MemoryBudgetManagerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("prbudget-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func paintedSetup() -> (TiledLayer, TiledLayer, UndoRedoManager) {
        var rng = SplitMix64(state: 33)
        let a = TiledLayer(name: "a", width: 2048, height: 1024)
        let b = TiledLayer(name: "b", width: 2048, height: 1024)
        let history = UndoRedoManager()
        for i in 0..<30 {
            let layer = i.isMultiple(of: 2) ? a : b
            history.perform("\(i)", on: layer) { layer.stamp(randomDab(&rng)) }
        }
        return (a, b, history)
    }

    func testPlentyOfMemoryDoesNothing() throws {
        let (a, b, history) = paintedSetup()
        let resident = a.residentBytes + b.residentBytes
        let manager = MemoryBudgetManager(spillDirectory: directory, availableBytes: { 4 << 30 })
        let report = try manager.relieve(layers: [a, b], history: history)
        XCTAssertEqual(report.pressure, .normal)
        XCTAssertEqual(report.freedBytes, 0)
        XCTAssertEqual(a.residentBytes + b.residentBytes, resident)
        XCTAssertFalse(report.suggestMergingLayers)
    }

    func testCriticalPressureSpillsEverythingButWorkingTiles() throws {
        let (a, b, history) = paintedSetup()
        let snapshotA = dump(a)
        let snapshotB = dump(b)
        let working = Set(a.storedTiles.prefix(2))
        let manager = MemoryBudgetManager(spillDirectory: directory, availableBytes: { 300 << 20 })
        manager.historyKeptInMemory = 3
        let report = try manager.relieve(layers: [a, b], history: history, activeLayer: a.id, workingTiles: working)

        XCTAssertEqual(report.pressure, .critical)
        XCTAssertGreaterThan(report.freedBytes, 0)
        XCTAssertTrue(report.suggestMergingLayers, "la mémoire disponible simulée ne remonte pas : il faut avertir")
        XCTAssertGreaterThan(b.spilledTileCount, 0)
        XCTAssertGreaterThan(history.entries.filter(\.isSpilled).count, 0)
        XCTAssertEqual(dump(a), snapshotA)
        XCTAssertEqual(dump(b), snapshotB)

        try manager.purgeSpill()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testUnknownAvailableMemoryUsesResidentLimit() throws {
        let (a, b, history) = paintedSetup()
        let resident = a.residentBytes + b.residentBytes + history.byteSize
        let manager = MemoryBudgetManager(spillDirectory: directory, availableBytes: { nil })
        manager.residentLimit = resident + resident / 10 // juste au-dessus : pression élevée
        let report = try manager.relieve(layers: [a, b], history: history)
        XCTAssertEqual(report.pressure, .elevated)
        XCTAssertGreaterThan(report.freedBytes, 0, "la recompression libère de la mémoire")
        XCTAssertEqual(a.spilledTileCount + b.spilledTileCount, 0, "pas de déversement en pression élevée")
    }
}
