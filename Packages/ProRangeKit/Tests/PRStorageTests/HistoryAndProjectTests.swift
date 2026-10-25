import Foundation
import PRCore
import PRStorage
import XCTest

final class UndoRedoTests: XCTestCase {
    /// Annuler / rétablir restitue l'état exact (octet par octet) après chaque opération.
    func testUndoRedoIsBitExact() throws {
        var rng = SplitMix64(state: 42)
        let layer = TiledLayer(name: "t", width: 2048, height: 1024)
        let history = UndoRedoManager()
        var snapshots = [dump(layer)]
        for i in 0..<12 {
            history.perform("trait \(i)", on: layer) {
                for _ in 0..<4 { layer.stamp(randomDab(&rng)) }
            }
            snapshots.append(dump(layer))
        }
        XCTAssertEqual(history.entries.count, 12)

        for i in stride(from: 11, through: 0, by: -1) {
            XCTAssertNotNil(try history.undo(in: [layer]))
            XCTAssertEqual(dump(layer), snapshots[i], "après annulation vers l'état \(i)")
        }
        XCTAssertFalse(history.canUndo)
        XCTAssertTrue(layer.storedTiles.isEmpty)

        for i in 1...12 {
            XCTAssertNotNil(try history.redo(in: [layer]))
            XCTAssertEqual(dump(layer), snapshots[i], "après rétablissement vers l'état \(i)")
        }
        XCTAssertFalse(history.canRedo)
    }

    func testNewOperationDropsRedoBranch() throws {
        let layer = TiledLayer(name: "t", width: 1024, height: 512)
        let history = UndoRedoManager()
        let dab = SphericalDab(center: [0, 0, -1], radius: 0.1, hardness: 1, color: [1, 0, 0, 1])
        history.perform("a", on: layer) { layer.stamp(dab) }
        history.perform("b", on: layer) { layer.fill([0, 0, 1, 1]) }
        try history.undo(in: [layer])
        history.perform("c", on: layer) { layer.fill(.zero) }
        XCTAssertEqual(history.entries.map(\.name), ["a", "c"])
        XCTAssertFalse(history.canRedo)
    }

    func testNoOpIsNotRecordedAndCapIsEnforced() {
        let layer = TiledLayer(name: "t", width: 1024, height: 512)
        let history = UndoRedoManager(maxSteps: 3)
        XCTAssertNil(history.perform("rien", on: layer) {})
        for i in 0..<5 {
            history.perform("\(i)", on: layer) { layer.fill([Float(i + 1) / 10, 0, 0, 1]) }
        }
        XCTAssertEqual(history.entries.map(\.name), ["2", "3", "4"])
    }
}

final class ProjectPackageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("prtests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSaveLoadRoundTripIsBitExact() throws {
        var rng = SplitMix64(state: 9)
        let background = TiledLayer(name: "Fond", width: 2048, height: 1024)
        background.fill([1, 1, 1, 1])
        let paint = TiledLayer(name: "Peinture", width: 2048, height: 1024)
        for _ in 0..<15 { paint.stamp(randomDab(&rng)) }
        paint.opacity = 0.75
        let small = TiledLayer(name: "8 bits", width: 2048, height: 1024, format: .rgba8)
        small.stamp(randomDab(&rng))
        small.isVisible = false

        let url = directory.appendingPathComponent("Test.prrange")
        try ProjectPackage.save(layers: [background, paint, small], to: url)
        // Deuxième sauvegarde : remplace le paquet existant.
        try ProjectPackage.save(layers: [background, paint, small], to: url)

        let (manifest, loaded) = try ProjectPackage.load(from: url)
        XCTAssertEqual(manifest.width, 2048)
        XCTAssertEqual(manifest.tileSize, TileSize.side)
        XCTAssertEqual(loaded.map(\.name), ["Fond", "Peinture", "8 bits"])
        XCTAssertEqual(loaded.map(\.id), [background.id, paint.id, small.id])
        XCTAssertEqual(loaded[1].opacity, 0.75)
        XCTAssertFalse(loaded[2].isVisible)
        XCTAssertEqual(loaded[2].format, .rgba8)
        for (original, copy) in zip([background, paint, small], loaded) {
            XCTAssertEqual(dump(copy), dump(original), original.name)
        }
    }

    func testMissingManifestFails() {
        XCTAssertThrowsError(try ProjectPackage.load(from: directory))
    }
}

final class OperationJournalTests: XCTestCase {
    func testAppendAndReadBack() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = try OperationJournal(url: url)
        try journal.appendStroke(centers: [[0, 0, -1], [0, 0.1, -0.99]], radius: 0.05, hardness: 0.5,
                                 color: [1, 0, 0, 1], spacing: 0.01, screenSpace: false)
        try journal.appendFill(start: [1, 0, 0], tolerance: 0.1, color: [0, 1, 0, 1])
        XCTAssertEqual(journal.currentIndex, 2)
        guard case .fill(let fill)? = try journal.operation(at: 1) else { return XCTFail("remplissage attendu") }
        XCTAssertEqual(fill.vec3Start, [1, 0, 0])

        // Une écriture après une lecture doit aller en fin de fichier.
        try journal.appendCheckpoint(name: "c", index: 2)
        var tags: [String] = []
        _ = try await journal.replay { op in
            switch op {
            case .stroke: tags.append("stroke")
            case .fill: tags.append("fill")
            case .checkpoint: tags.append("checkpoint")
            default: tags.append("autre")
            }
        }
        XCTAssertEqual(tags, ["stroke", "fill", "checkpoint"])
    }
}
