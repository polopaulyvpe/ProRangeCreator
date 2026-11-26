import Foundation
import PRCore
@testable import PRImaging
import XCTest

/// Les jeux de pinceaux de ProCraft livrés dans l'app (App/ProCraftBrushes) : chacun se lit en entier avec notre import.
/// Le journal liste les réglages encore ignorés (lignes « PROCRAFT »), pour savoir quoi gérer ensuite.
final class ProCraftBrushesTests: XCTestCase {
    private var folder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../App/ProCraftBrushes").standardized
    }

    func testEverySetReadsCompletely() throws {
        let index = try String(contentsOf: folder.appendingPathComponent("procraft-sets.tsv"), encoding: .utf8)
        var total = 0
        // Écrit dans un fichier que la CI affiche (en parallèle, la sortie des tests réussis est masquée).
        var report: [String] = []
        var ignored: [String: Int] = [:]
        for line in index.split(separator: "\n") {
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count >= 3, let count = Int(parts[2]) else { continue }
            let data = try Data(contentsOf: folder.appendingPathComponent(parts[0]))
            let presets = try ProcreateBrushImport.read(data: data, fallbackName: parts[1])
            XCTAssertEqual(presets.count, count, parts[1])
            for preset in presets {
                XCTAssertFalse(preset.name.isEmpty)
                XCTAssertGreaterThan(preset.settings.radiusDegrees, 0, preset.name)
                XCTAssertTrue(preset.settings.radiusDegrees.isFinite && preset.settings.spacing.isFinite, preset.name)
                // « N autres réglages non gérés : a, b, c » : chaque clé compte.
                for item in preset.ignored {
                    if let range = item.range(of: "non gérés : ") {
                        for key in item[range.upperBound...].split(separator: ",") {
                            ignored[key.trimmingCharacters(in: .whitespaces), default: 0] += 1
                        }
                    } else {
                        ignored[String(item.prefix(60)), default: 0] += 1
                    }
                }
            }
            if parts[1] == "Watercolors" {
                for preset in presets {
                    report.append("PROCRAFT aquarelle \(preset.name) : repris \(preset.mapped.count), ignorés \(preset.ignored.joined(separator: " | "))")
                }
            }
            total += presets.count
        }
        report.append("PROCRAFT \(total) pinceaux lus")
        for (key, n) in ignored.sorted(by: { $0.value > $1.value }).prefix(60) { report.append("PROCRAFT ignoré \(n) × \(key)") }
        let text = report.joined(separator: "\n")
        try? text.write(toFile: "/tmp/procraft-report.txt", atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(total, 500)
    }

    /// Trait d'essai sur le CPU (même calcul que la toile) : dabs du principal et du secondaire le long de l'équateur,
    /// trait à masque comme sur la toile. Renvoie l'alpha maximal et l'aire peinte (texels d'alpha > 0,05).
    static func trial(_ s: BrushSettings, pressure: Double) -> (maxAlpha: Float, painted: Int) {
        let layer = TiledLayer(name: "essai", width: 1024, height: 512, format: .rgba16Float)
        let buffer = StrokeBuffer()
        let style = s.strokeStyle(color: [0, 0, 0], mode: .paint)
        let radius = s.radius(pressure: pressure)
        let length = min(1.0, max(0.02, 40 * radius))
        var dabs: [SphericalDab] = []
        func lay(_ brush: BrushSettings, secondary: Bool) {
            let step = max(brush.spacing(radius: brush.radius(pressure: pressure), random: 0.5), length / 300)
            var t = 0.0
            var previous: Vec3?
            while t <= length {
                let center = Equirect.direction(latitude: 0, longitude: t - length / 2)
                let angle = previous.map { BrushSettings.strokeAngle(from: $0, to: center) } ?? 0
                let context = StrokeContext(distance: t, speed: 0.2, tilt: 0.2, grainOffset: [0.3, 0.6], rotationOffset: 0.4)
                var dab = brush.dab(at: center, pressure: pressure, color: [0, 0, 0], mode: .paint, strokeAngle: angle,
                                    random: DabRandom.none, context: context)
                dab.secondary = secondary
                dabs.append(dab)
                previous = center
                t += step
            }
        }
        lay(s, secondary: false)
        if let second = s.resolvedSecondary { lay(second, secondary: true) }
        for dab in dabs { _ = layer.stamp(dab, into: buffer, style: style) }
        var maxAlpha: Float = 0
        var painted = 0
        for coord in layer.storedTiles {
            for p in layer.tileFloatPixels(coord) {
                maxAlpha = max(maxAlpha, p.w)
                if p.w > 0.05 { painted += 1 }
            }
        }
        return (maxAlpha, painted)
    }

    /// Chaque pinceau laisse une marque visible, au doigt (pression 1) et au Pencil appuyé moyennement (0,5).
    /// Le rapport liste ceux qui ne peignent pas, avec les réglages qui peuvent l'expliquer.
    func testEveryBrushPaintsSomething() throws {
        let index = try String(contentsOf: folder.appendingPathComponent("procraft-sets.tsv"), encoding: .utf8)
        var report: [String] = []
        var invisible = 0
        var total = 0
        for line in index.split(separator: "\n") {
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count >= 3 else { continue }
            let data = try Data(contentsOf: folder.appendingPathComponent(parts[0]))
            for preset in try ProcreateBrushImport.read(data: data, fallbackName: parts[1]) {
                total += 1
                let s = preset.settings
                let finger = Self.trial(s, pressure: 1)
                let pen = Self.trial(s, pressure: 0.5)
                guard finger.maxAlpha < 0.15 || pen.maxAlpha < 0.15 else { continue }
                invisible += 1
                let shapeMean = s.shape.map { $0.values.reduce(0, +) / Float($0.values.count) } ?? -1
                let grainMean = s.grain.map { $0.values.reduce(0, +) / Float($0.values.count) } ?? -1
                report.append(String(format: "PROCRAFT invisible %@ / %@ : doigt %.3f (%ld) Pencil %.3f (%ld) | rayon %.2f° opacité %.2f flux %.2f dureté %.2f rendu %@ espacement %.2f forme %.3f grain %.3f prof %.2f double %@ combin %@ pression→opacité %@ min %.2f-%.2f",
                                     parts[1], preset.name, finger.maxAlpha, finger.painted, pen.maxAlpha, pen.painted,
                                     s.radiusDegrees, s.opacity, s.flow, s.hardness, s.rendering.label, s.spacing, shapeMean, grainMean,
                                     s.grainDepth, s.resolvedSecondary == nil ? "non" : "oui", s.dualBlendMode.label,
                                     s.pressureAffectsOpacity ? "oui" : "non", s.minOpacity, s.maxOpacity))
            }
        }
        report.insert("PROCRAFT \(invisible) pinceaux invisibles sur \(total)", at: 0)
        try? report.joined(separator: "\n").write(toFile: "/tmp/procraft-invisible.txt", atomically: true, encoding: .utf8)
    }
}
