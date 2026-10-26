import Foundation
import PRCore
import PRStorage
import XCTest

final class ProjectLibraryTests: XCTestCase {
    private var directory: URL!
    private var library: ProjectLibrary!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("prlib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        library = ProjectLibrary(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func stack(color: SIMD4<Float>) -> LayerStack {
        let stack = LayerStack(width: 512, height: 256)
        stack.items[0].layer!.stamp(SphericalDab(center: [0, 0, -1], radius: 0.4, hardness: 1, color: color))
        return stack
    }

    func testNamesDuplicateRenameDelete() throws {
        XCTAssertEqual(ProjectLibrary.sanitized("  a/b:c  "), "a-b-c")
        XCTAssertEqual(ProjectLibrary.sanitized(""), "Sans titre")
        let first = library.uniqueURL(for: "Ciel")
        try ProjectPackage.save(stack: stack(color: [1, 0, 0, 1]), to: first, createdAt: Date())
        XCTAssertEqual(library.uniqueURL(for: "Ciel").lastPathComponent, "Ciel 2.prrange", "nom déjà pris : numéroté")
        XCTAssertEqual(library.uniqueURL(for: "Ciel", except: first), first, "renommer vers son propre nom")

        try library.createSnapshot(named: "avant", stack: stack(color: [0, 1, 0, 1]), of: first, createdAt: Date())
        let copy = try library.duplicate(first)
        XCTAssertEqual(copy.lastPathComponent, "Ciel copie.prrange")
        XCTAssertEqual(library.snapshots(of: copy).map(\.name), ["avant"], "les instantanés suivent la copie")

        let renamed = try library.rename(first, to: "Aube")
        XCTAssertEqual(renamed.lastPathComponent, "Aube.prrange")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(library.snapshots(of: renamed).count, 1, "les instantanés suivent le renommage")
        XCTAssertEqual(try library.rename(renamed, to: "Ciel copie").lastPathComponent, "Ciel copie 2.prrange")

        XCTAssertEqual(Set(library.projects().map(\.lastPathComponent)), ["Ciel copie.prrange", "Ciel copie 2.prrange"],
                       "les dossiers d'instantanés ne sont pas des projets")
        try library.delete(copy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.snapshotsDirectory(for: copy).path))
    }

    func testSnapshotKeepsItsOwnContent() throws {
        let project = library.uniqueURL(for: "Nuit")
        try ProjectPackage.save(stack: stack(color: [0, 0, 1, 1]), to: project, createdAt: Date())
        let snapshot = try library.createSnapshot(named: "bleu", stack: stack(color: [0, 0, 1, 1]), of: project, createdAt: Date())
        // Le projet est réenregistré avec un autre contenu : l'instantané n'a pas bougé.
        try ProjectPackage.save(stack: stack(color: [1, 1, 0, 1]), to: project, createdAt: Date())
        let (_, restored) = try ProjectPackage.loadStack(from: snapshot.url)
        let p = restored.items[0].layer!.pixel(x: 256, y: 128)
        XCTAssertEqual(p.z, 1, accuracy: 1e-3)
        XCTAssertEqual(p.x, 0, accuracy: 1e-3)
        try library.deleteSnapshot(snapshot)
        XCTAssertTrue(library.snapshots(of: project).isEmpty)
    }
}
