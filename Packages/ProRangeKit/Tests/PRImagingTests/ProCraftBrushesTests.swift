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
}
