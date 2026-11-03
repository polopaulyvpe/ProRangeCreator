import Foundation
import PRCore
import PRStorage
import simd
import XCTest

final class LayerStackTests: XCTestCase {
    private func makeStack() -> LayerStack { LayerStack(width: 1024, height: 512) }

    private func paint(_ item: StackItem?, color: SIMD4<Float>, at center: Vec3 = [0, 0, -1], radius: Double = 0.3) {
        item?.layer?.stamp(SphericalDab(center: center, radius: radius, hardness: 1, color: color))
    }

    /// Pixel du centre (face à -Z) dans le composite de la pile.
    private func centerPixel(_ stack: LayerStack, paper: SIMD3<Float>? = [1, 1, 1]) -> SIMD4<Float> {
        let tile = LayerCompositor.compositeTile(TileCoord(x: 2, y: 1), stack: stack, paper: paper, space: .perceptual)
        return tile[0] // pixel (512, 256) : coin haut gauche de la tuile (2, 1)
    }

    func testStructureOperations() {
        let stack = makeStack()
        let first = stack.items[0]
        let second = stack.addLayer(above: first.id)!
        let third = stack.addLayer(above: first.id)!
        XCTAssertEqual(stack.items.map(\.id), [first.id, third.id, second.id], "inséré juste au-dessus")

        stack.move(third.id, by: 1)
        XCTAssertEqual(stack.items.map(\.id), [first.id, second.id, third.id])
        stack.move(third.id, by: 1)
        XCTAssertEqual(stack.items.map(\.id), [first.id, second.id, third.id], "déjà en haut")

        let group = stack.groupWithBelow(third.id)!
        XCTAssertEqual(stack.items.map(\.id), [first.id, second.id, third.id, group.id])
        XCTAssertEqual(stack.children(of: group.id).map(\.id), [second.id, third.id])
        XCTAssertEqual(stack.children(of: nil).map(\.id), [first.id, group.id])

        stack.move(group.id, by: -1)
        XCTAssertEqual(stack.items.map(\.id), [second.id, third.id, group.id, first.id], "le groupe bouge avec ses enfants")

        stack.ungroup(group.id)
        XCTAssertEqual(stack.children(of: nil).map(\.id), [second.id, third.id, first.id])

        stack.remove(second.id)
        stack.remove(third.id)
        stack.remove(first.id)
        XCTAssertEqual(stack.layerCount, 1, "le dernier calque ne se supprime pas")
    }

    func testLayerLimitAndDuplicate() {
        let stack = makeStack()
        paint(stack.items[0], color: [1, 0, 0, 1])
        let copy = stack.duplicate(stack.items[0].id)!
        XCTAssertNotEqual(copy.layer!.id, stack.items[0].layer!.id)
        XCTAssertEqual(copy.layer!.storedTiles.count, stack.items[0].layer!.storedTiles.count)
        copy.layer!.fill(.zero)
        XCTAssertFalse(stack.items[0].layer!.storedTiles.isEmpty, "copie indépendante")

        while stack.canAddLayer { stack.addLayer() }
        XCTAssertEqual(stack.layerCount, LayerStack.maxLayers)
        XCTAssertNil(stack.addLayer())
    }

    func testStructureUndoRedo() throws {
        let stack = makeStack()
        let history = UndoRedoManager()
        let before = stack.items
        let added = stack.addLayer()!
        history.record(HistoryEntry(name: "ajout", layerID: added.id, deltas: [], structure: (before, stack.items)))
        try history.undo(in: stack)
        XCTAssertEqual(stack.items.map(\.id), before.map(\.id))
        try history.redo(in: stack)
        XCTAssertEqual(stack.items.last?.id, added.id)
    }

    func testBlendModesInComposite() {
        let stack = makeStack()
        paint(stack.items[0], color: [0.5, 0.5, 0.5, 1])
        let top = stack.addLayer()!
        paint(top, color: [0.5, 0.5, 0.5, 1])

        // Normal opaque : on voit le calque du dessus.
        XCTAssertEqual(centerPixel(stack).x, 0.5, accuracy: 1e-3)
        // Produit en perceptuel : 0,5 × 0,5 encodés.
        stack.update(top.id) { $0.blendMode = .multiply }
        let expected = ColorTransfer.toLinear(ColorTransfer.toEncoded(0.5) * ColorTransfer.toEncoded(0.5))
        XCTAssertEqual(centerPixel(stack).x, expected, accuracy: 1e-3)
        // Calque masqué : ignoré.
        stack.update(top.id) { $0.isVisible = false }
        XCTAssertEqual(centerPixel(stack).x, 0.5, accuracy: 1e-3)
        // Hors peinture : le papier.
        let corner = LayerCompositor.compositeTile(TileCoord(x: 0, y: 0), stack: stack, paper: [1, 1, 1], space: .perceptual)
        XCTAssertEqual(corner[0], [1, 1, 1, 1])
    }

    func testMaskClippingAndGroups() {
        let stack = makeStack()
        let base = stack.items[0]
        paint(base, color: [0, 0, 1, 1], radius: 0.1)
        let clipped = stack.addLayer()!
        clipped.layer!.fill([1, 0, 0, 1])
        stack.update(clipped.id) { $0.isClipped = true }

        // Écrêté : rouge seulement dans le disque bleu, papier ailleurs.
        XCTAssertEqual(centerPixel(stack).x, 1, accuracy: 1e-3)
        XCTAssertEqual(centerPixel(stack).z, 0, accuracy: 1e-3)
        let outside = LayerCompositor.compositeTile(TileCoord(x: 0, y: 0), stack: stack, paper: [1, 1, 1], space: .perceptual)[0]
        XCTAssertEqual(outside, [1, 1, 1, 1])

        // Masque noir sur la base : base et calque écrêté disparaissent.
        stack.addMask(base.id)
        stack.item(base.id)!.mask!.fill([0, 0, 0, 1])
        XCTAssertEqual(centerPixel(stack), [1, 1, 1, 1])
        stack.removeMask(base.id)

        // Groupe isolé : un Produit dans un groupe ne voit pas ce qui est sous le groupe (ici le papier gris),
        // là où la base du groupe est vide (coin de la toile).
        stack.update(clipped.id) { $0.isClipped = false; $0.blendMode = .multiply }
        let group = stack.groupWithBelow(clipped.id)!
        func corner() -> SIMD4<Float> {
            LayerCompositor.compositeTile(TileCoord(x: 0, y: 0), stack: stack, paper: [0.5, 0.5, 0.5], space: .perceptual)[0]
        }
        XCTAssertEqual(corner().x, 1, accuracy: 1e-3, "isolé : le rouge apparaît tel quel")
        stack.ungroup(group.id)
        XCTAssertEqual(corner().x, ColorTransfer.toLinear(ColorTransfer.toEncoded(0.5)), accuracy: 1e-3, "sans groupe : rouge × gris")
    }

    func testMergeDownAndFlattenAreUndoable() throws {
        let stack = makeStack()
        paint(stack.items[0], color: [0.2, 0.6, 0.2, 1])
        let top = stack.addLayer()!
        paint(top, color: [0.9, 0.1, 0.1, 0.5], radius: 0.2)
        stack.update(top.id) { $0.blendMode = .screen; $0.opacity = 0.8 }
        let reference = centerPixel(stack)
        let history = UndoRedoManager()

        let merge = try XCTUnwrap(stack.mergeDown(top.id, space: .perceptual))
        history.record(merge)
        XCTAssertEqual(stack.layerCount, 1)
        XCTAssertLessThan(simd_length(centerPixel(stack) - reference), 2e-3, "même image après fusion")

        try history.undo(in: stack)
        XCTAssertEqual(stack.layerCount, 2)
        XCTAssertLessThan(simd_length(centerPixel(stack) - reference), 1e-6, "annulation exacte")

        let flatten = try XCTUnwrap(stack.flatten(space: .perceptual))
        history.record(flatten)
        XCTAssertEqual(stack.items.count, 1)
        XCTAssertLessThan(simd_length(centerPixel(stack) - reference), 2e-3)
        try history.undo(in: stack)
        XCTAssertEqual(stack.layerCount, 2)
        try history.redo(in: stack)
        XCTAssertEqual(stack.layerCount, 1)
        XCTAssertLessThan(simd_length(centerPixel(stack) - reference), 2e-3)
    }

    func testStackSaveLoadRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("prstack-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stack = makeStack()
        paint(stack.items[0], color: [0.3, 0.3, 0.8, 1])
        let top = stack.addLayer(name: "Dessus")!
        paint(top, color: [1, 0.5, 0, 1], radius: 0.15)
        stack.update(top.id) { $0.blendMode = .overlay; $0.opacity = 0.6; $0.alphaLock = true }
        stack.addMask(top.id)
        let group = stack.groupWithBelow(top.id)!
        stack.update(group.id) { $0.isVisible = true; $0.name = "Mon groupe" }
        let reference = centerPixel(stack)

        let url = directory.appendingPathComponent("P.prrange")
        try ProjectPackage.save(stack: stack, to: url)
        let (manifest, loaded) = try ProjectPackage.loadStack(from: url)
        XCTAssertEqual(manifest.formatVersion, 2)
        XCTAssertEqual(loaded.items.map(\.id), stack.items.map(\.id))
        XCTAssertEqual(loaded.items.map(\.name), stack.items.map(\.name))
        XCTAssertEqual(loaded.item(top.id)?.blendMode, .overlay)
        XCTAssertEqual(loaded.item(top.id)?.alphaLock, true)
        XCTAssertNotNil(loaded.item(top.id)?.mask)
        XCTAssertEqual(loaded.item(top.id)?.parent, group.id)
        XCTAssertEqual(centerPixel(loaded), reference)

        // Un projet v1 (calques seuls) s'ouvre comme une pile plate.
        let v1 = directory.appendingPathComponent("V1.prrange")
        try ProjectPackage.save(layers: [stack.items[0].layer!], to: v1)
        let (_, flat) = try ProjectPackage.loadStack(from: v1)
        XCTAssertEqual(flat.items.count, 1)
    }

    func testPlaceGroupAndCollapse() {
        let stack = makeStack()
        let a = stack.items[0]
        let b = stack.addLayer()!
        let c = stack.addLayer()!
        // Panneau (haut → bas) : c, b, a. a sous c : c, a, b.
        XCTAssertTrue(stack.place(a.id, belowRow: c.id))
        XCTAssertEqual(stack.items.map(\.id), [b.id, a.id, c.id])
        XCTAssertTrue(stack.place(b.id, belowRow: nil), "tout en haut")
        XCTAssertEqual(stack.items.map(\.id), [a.id, c.id, b.id])
        XCTAssertFalse(stack.place(b.id, belowRow: b.id))

        let group = stack.group([a.id, b.id])!
        XCTAssertEqual(group.name, "Nouveau groupe")
        XCTAssertEqual(stack.children(of: group.id).map(\.id), [a.id, b.id], "ordre conservé")
        XCTAssertEqual(stack.children(of: nil).map(\.id), [c.id, group.id], "à la place du plus haut")
        XCTAssertFalse(stack.place(group.id, belowRow: a.id), "pas dans lui-même")

        // Sous un groupe déplié : premier enfant. Sous un groupe replié : frère dessous.
        XCTAssertTrue(stack.place(c.id, belowRow: group.id))
        XCTAssertEqual(stack.item(c.id)?.parent, group.id)
        XCTAssertEqual(stack.children(of: group.id).last?.id, c.id)
        stack.update(group.id) { $0.isCollapsed = true }
        XCTAssertTrue(stack.place(c.id, belowRow: group.id))
        XCTAssertNil(stack.item(c.id)?.parent)
        XCTAssertEqual(stack.children(of: nil).map(\.id), [c.id, group.id])
    }

    func testLockReferenceAndDuplicate() {
        let stack = makeStack()
        let a = stack.items[0]
        let b = stack.addLayer()!
        let group = stack.groupWithBelow(b.id)!
        stack.update(group.id) { $0.isLocked = true }
        XCTAssertTrue(stack.isLocked(a.id), "verrouillé par son groupe")
        stack.update(group.id) { $0.isLocked = false }
        stack.update(a.id) { $0.isLocked = true }
        let copy = stack.duplicate(a.id)!
        XCTAssertEqual(copy.name, a.name, "même nom")
        XCTAssertTrue(copy.isLocked, "même verrou")

        stack.setReference(a.id, true)
        XCTAssertTrue(stack.referenceLayer === a.layer)
        stack.setReference(b.id, true)
        XCTAssertTrue(stack.referenceLayer === b.layer, "une seule référence")
        XCTAssertFalse(stack.item(a.id)!.isReference)
    }

    func testMergeSeveralMatchesComposite() throws {
        let stack = makeStack()
        paint(stack.items[0], color: [0.2, 0.6, 0.2, 1])
        let middle = stack.addLayer()!
        paint(middle, color: [0.1, 0.1, 0.9, 0.6], radius: 0.25)
        stack.update(middle.id) { $0.blendMode = .multiply }
        let top = stack.addLayer()!
        paint(top, color: [0.9, 0.1, 0.1, 0.5], radius: 0.2)
        stack.update(top.id) { $0.opacity = 0.7 }
        let reference = centerPixel(stack)
        let history = UndoRedoManager()

        let entry = try XCTUnwrap(stack.merge([top.id, stack.items[0].id, middle.id], space: .perceptual))
        history.record(entry)
        XCTAssertEqual(stack.layerCount, 1)
        XCTAssertLessThan(simd_length(centerPixel(stack) - reference), 2e-3, "même image après fusion")
        try history.undo(in: stack)
        XCTAssertEqual(stack.layerCount, 3)
        XCTAssertLessThan(simd_length(centerPixel(stack) - reference), 1e-6, "annulation exacte")
    }

    func testNewPropertiesAndBackgroundSaved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("prstack-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stack = makeStack()
        let top = stack.addLayer()!
        let group = stack.groupWithBelow(top.id)!
        stack.update(top.id) { $0.isLocked = true }
        stack.setReference(top.id, true)
        stack.update(group.id) { $0.isCollapsed = true }
        stack.background = [0.2, 0.3, 0.4]
        stack.backgroundVisible = false
        XCTAssertEqual(centerPixel(stack, paper: stack.backgroundVisible ? stack.background : nil), .zero)

        let url = directory.appendingPathComponent("P.prrange")
        try ProjectPackage.save(stack: stack, to: url)
        let loaded = try ProjectPackage.loadStack(from: url).stack
        XCTAssertEqual(loaded.item(top.id)?.isLocked, true)
        XCTAssertEqual(loaded.item(top.id)?.isReference, true)
        XCTAssertEqual(loaded.item(group.id)?.isCollapsed, true)
        XCTAssertEqual(loaded.background, [0.2, 0.3, 0.4])
        XCTAssertFalse(loaded.backgroundVisible)
    }

    func testSelectContentAndReferenceFill() {
        let stack = makeStack()
        let painted = stack.items[0]
        paint(painted, color: [1, 1, 1, 1], radius: 0.3)
        let selection = SelectionMask(width: 1024, height: 512)
        selection.selectContent(of: painted.layer!)
        XCTAssertEqual(selection.value(x: 512, y: 256), 1, accuracy: 1e-3, "contenu sélectionné")
        XCTAssertEqual(selection.value(x: 10, y: 256), 0, "vide ailleurs")

        // Remplissage d'un calque vide guidé par la référence : seul le disque est rempli.
        let target = stack.addLayer()!.layer!
        target.floodFill(from: [0, 0, -1], color: [0, 0, 1, 1], threshold: 0.1, space: .perceptual, reference: painted.layer)
        let sampler = LayerSampler(target)
        XCTAssertGreaterThan(sampler.texel(512, 256).w, 0.99)
        XCTAssertEqual(sampler.texel(10, 256).w, 0)
    }
}
