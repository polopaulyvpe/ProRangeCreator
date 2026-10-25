import PRCore
import PREngine
import PRStorage
import simd
import SwiftUI
import UIKit

/// Lot C : liquify, QuickShape, texte, distorsion par quatre coins.
extension CanvasSession {
    // MARK: - Liquify

    func applyLiquify(_ centers: [Vec3], pressure: Double) {
        let strength = Float(liquifyStrength)
        let mode = liquifyMode
        for center in centers {
            for (i, image) in symmetry.images(of: center).enumerated() where i < smudgePrevious.count {
                let previous = smudgePrevious[i]
                let dab = dab(at: image, pressure: pressure)
                canvas?.edit { $0.liquify(dab, mode: mode, from: previous, strength: strength) }
                smudgePrevious[i] = image
            }
        }
    }

    // MARK: - QuickShape

    /// Commence à surveiller le trait : s'il s'arrête 0,6 s sans bouger, on tente de le remplacer par une ligne ou un cercle.
    func beginQuickShapeWatch(at d: Vec3, pressure: Double) {
        quickShapeApplied = false
        quickShapePoints = [d]
        quickShapePressure = pressure
        quickShapeLastMove = CACurrentMediaTime()
        stopQuickShapeWatch()
        guard quickShapeEnabled, tool == .brush || tool == .eraser else { return }
        quickShapeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.quickShapeTick() }
        }
    }

    func noteQuickShapePoint(_ d: Vec3) {
        guard let last = quickShapePoints.last, Sphere.angle(last, d) > 0.002 else { return }
        quickShapePoints.append(d)
        quickShapeLastMove = CACurrentMediaTime()
    }

    func stopQuickShapeWatch() {
        quickShapeTimer?.invalidate()
        quickShapeTimer = nil
    }

    private func quickShapeTick() {
        guard let canvas, canvas.isStroking, !quickShapeApplied,
              CACurrentMediaTime() - quickShapeLastMove > 0.6, quickShapePoints.count >= 4 else { return }
        stopQuickShapeWatch()
        guard let shape = QuickShape.fit(quickShapePoints) else { return }
        // Le trait à main levée disparaît et la forme propre est peinte à sa place, dans le même trait.
        canvas.cancelStroke()
        canvas.beginStroke()
        let spacing = max(settings.radius(pressure: quickShapePressure) * settings.spacing, 1e-4)
        canvas.add(symmetricDabs(shape.points(spacing: spacing), pressure: quickShapePressure))
        quickShapeApplied = true
        if case .line = shape { fileMessage = "QuickShape : ligne" } else { fileMessage = "QuickShape : cercle" }
    }

    // MARK: - Distorsion

    func startDistort() {
        strokeCancelled()
        cancelTransform()
        guard let target = editTarget else { return }
        let mask = hasSelection ? selection : nil
        let origin = mask?.centroid() ?? view.direction(atNDC: .zero, aspect: lastAspect) ?? [0, 0, -1]
        let half = min(1.0, max(5 * .pi / 180, mask?.angularRadius(around: origin) ?? 20 * .pi / 180))
        canvas?.setFloating(target.masked(by: mask))
        distort = SphericalDistort(origin: origin, halfAngle: half)
    }

    /// Prend la poignée la plus proche du doigt (en NDC), s'il y en a une assez près.
    func grabDistortCorner(ndc: SIMD2<Double>) {
        guard let distort else { return }
        let parameters = view.parameters(aspect: lastAspect)
        var best: (index: Int, distance: Double)?
        for (i, d) in distort.targetDirections.enumerated() {
            guard let p = parameters.ndc(of: d) else { continue }
            let distance = simd_distance(p, ndc)
            if distance < (best?.distance ?? 0.15) { best = (i, distance) }
        }
        activeCorner = best?.index
    }

    func moveDistortCorner(to d: Vec3) {
        guard let index = activeCorner else { return }
        distort?.moveCorner(index, to: d)
    }

    func applyDistort() {
        guard let d = distort, let target = editTarget else { return }
        defer { cancelDistort() }
        guard d.sourceCorners != d.targetCorners, d.homography != nil else { return }
        let mask = hasSelection ? selection : nil
        target.beginOperation()
        target.applyDistort(d, selection: mask)
        let deltas = target.endOperation()
        var others: [(layerID: UUID, deltas: [TileDelta])] = []
        if let mask {
            mask.layer.beginOperation()
            mask.distort(d)
            let maskDeltas = mask.layer.endOperation()
            if !maskDeltas.isEmpty { others.append((mask.layer.id, maskDeltas)) }
        }
        guard !deltas.isEmpty || !others.isEmpty else { return }
        if deltas.isEmpty, let first = others.first {
            history.record(HistoryEntry(name: "Distorsion", layerID: first.layerID, deltas: first.deltas))
        } else {
            history.record(HistoryEntry(name: "Distorsion", layerID: target.id, deltas: deltas, otherLayers: others))
        }
        refreshHistory()
        selectionUpdated()
        structureChanged()
    }

    func cancelDistort() {
        guard distort != nil else { return }
        distort = nil
        activeCorner = nil
        canvas?.setFloating(nil)
    }

    // MARK: - Texte

    /// Ajoute un nouveau calque avec le texte posé face à la vue (une seule entrée d'historique).
    func addText(_ text: String, angularWidthDegrees: Double) {
        strokeCancelled()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, stack.canAddLayer, let image = Self.renderText(trimmed, color: color) else { return }
        let center = view.direction(atNDC: .zero, aspect: lastAspect) ?? [0, 0, -1]
        let before = stack.items
        guard let item = stack.addLayer(above: activeID, name: "Texte : \(trimmed.prefix(20))"), let layer = item.layer else { return }
        layer.beginOperation()
        layer.placeImage(image.pixels, width: image.width, height: image.height, center: center,
                         angularWidth: angularWidthDegrees * .pi / 180)
        let deltas = layer.endOperation()
        history.record(HistoryEntry(name: "Texte", layerID: layer.id, deltas: deltas, structure: (before, stack.items)))
        refreshHistory()
        selectLayer(item.id)
    }

    /// Texte rendu par UIKit en RGBA linéaire prémultiplié (lignes de haut en bas).
    static func renderText(_ text: String, color: SIMD3<Double>) -> (pixels: [SIMD4<Float>], width: Int, height: Int)? {
        let font = UIFont.systemFont(ofSize: 160, weight: .bold)
        let uiColor = UIColor(red: color.x, green: color.y, blue: color.z, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: uiColor]
        let size = (text as NSString).size(withAttributes: attributes)
        let width = Int(size.width.rounded(.up)) + 16
        let height = Int(size.height.rounded(.up)) + 16
        guard width > 16, height > 16, width * height < 40_000_000, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // Repère UIKit (origine en haut à gauche) : la première ligne en mémoire est le haut du texte.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(context)
            (text as NSString).draw(at: CGPoint(x: 8, y: 8), withAttributes: attributes)
            UIGraphicsPopContext()
            return true
        }
        guard drawn else { return nil }
        var pixels = [SIMD4<Float>](repeating: .zero, count: width * height)
        for i in pixels.indices {
            let a = Float(bytes[i * 4 + 3]) / 255
            guard a > 0 else { continue }
            let straight = SIMD3<Float>(Float(bytes[i * 4]), Float(bytes[i * 4 + 1]), Float(bytes[i * 4 + 2])) / 255 / a
            let linear = ColorTransfer.toLinear(simd_clamp(straight, .zero, .one))
            pixels[i] = SIMD4<Float>(linear.x * a, linear.y * a, linear.z * a, a)
        }
        return (pixels, width, height)
    }
}

/// Réglages du liquify.
struct LiquifyOptions: View {
    @Bindable var session: CanvasSession

    var body: some View {
        Picker("Mode", selection: $session.liquifyMode) {
            ForEach(LiquifyMode.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 280)
        VStack(alignment: .leading, spacing: 2) {
            Text("Force \(Int(session.liquifyStrength * 100)) %").font(.caption)
            Slider(value: $session.liquifyStrength, in: 0.05...1)
        }
        .frame(width: 130)
    }
}

/// Poignées de la distorsion, redessinées à chaque image (la vue peut bouger pendant qu'on tire les coins).
struct DistortHandlesOverlay: View {
    let session: CanvasSession

    var body: some View {
        if session.distort != nil {
            TimelineView(.animation) { _ in
                GeometryReader { geo in
                    let aspect = Double(geo.size.width / max(geo.size.height, 1))
                    let parameters = session.view.parameters(aspect: aspect)
                    let points: [CGPoint?] = (session.distort?.targetDirections ?? []).map { d in
                        parameters.ndc(of: d).map { CGPoint(x: ($0.x + 1) / 2 * geo.size.width, y: (1 - $0.y) / 2 * geo.size.height) }
                    }
                    ZStack {
                        Path { path in
                            let visible = points.compactMap { $0 }
                            guard visible.count == 4 else { return }
                            path.addLines(visible + [visible[0]])
                        }
                        .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        ForEach(0..<points.count, id: \.self) { i in
                            if let p = points[i] {
                                Circle()
                                    .fill(.white)
                                    .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 1))
                                    .frame(width: 22, height: 22)
                                    .position(p)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Saisie d'un texte, posé sur un nouveau calque face à la vue.
struct TextSheet: View {
    @Bindable var session: CanvasSession
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var width = 30.0

    var body: some View {
        NavigationStack {
            Form {
                TextField("Texte", text: $text)
                VStack(alignment: .leading) {
                    Text("Largeur sur la sphère : \(Int(width))°")
                    Slider(value: $width, in: 5...120)
                }
                Text("Le texte est posé face à la direction regardée, dans la couleur courante, sur un nouveau calque. Il est ensuite peint comme une image : il ne se modifie plus comme un texte.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Ajouter du texte")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ajouter") {
                        session.addText(text, angularWidthDegrees: width)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// Coins de la distorsion en cours.
struct DistortPanel: View {
    @Bindable var session: CanvasSession

    var body: some View {
        if session.distort != nil {
            HStack(spacing: 14) {
                Text("Tire les quatre coins").font(.caption).foregroundStyle(.secondary)
                Button("Annuler") { session.cancelDistort() }
                Button("Appliquer") { session.applyDistort() }
                    .buttonStyle(.borderedProminent)
            }
            .font(.callout)
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
