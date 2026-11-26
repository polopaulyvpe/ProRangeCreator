import Foundation
import PRCore
import PRImaging

/// Pinceaux de ProCraft (github.com/artcraft-android/procraft, MIT ou Apache-2.0, voir NOTICE.md), livrés dans l'app :
/// un `.brushset` par jeu, écrit par ProCraft lui-même (réglages, formes et grains dessinés par son code), lu par
/// notre import Procreate à la première ouverture du jeu, puis gardé en mémoire.
@MainActor
enum ProCraftLibrary {
    struct BrushSetFile: Identifiable {
        let id: String
        /// Nom affiché (en français).
        let name: String
        let url: URL
        let count: Int
    }

    /// Noms français des jeux ; les aquarelles d'abord (voir `order`).
    static let frenchNames: [String: String] = [
        "Watercolors": "Aquarelle", "Watercolor": "Aquarelle", "Watercolours": "Aquarelle",
        "Painting": "Peinture", "Sketching": "Croquis", "Inking": "Encrage", "Drawing": "Dessin",
        "Calligraphy": "Calligraphie", "Airbrushing": "Aérographe", "Spray Paints": "Bombe", "Spray Paint": "Bombe",
        "Charcoals": "Fusains", "Textures": "Textures", "Abstract": "Abstrait", "Elements": "Éléments",
        "Artistic": "Artistique", "Industrial": "Industriel", "Luminance": "Lumière", "Organic": "Organique",
        "Pencils": "Crayons", "Pens": "Stylos", "Markers": "Feutres", "Pastels": "Pastels", "Oils": "Huile",
        "Acrylics": "Acrylique", "Gouache": "Gouache", "Inks": "Encres", "Brushes": "Pinceaux", "Effects": "Effets",
        "Touch-ups": "Retouches", "Retro": "Rétro", "Vintage": "Vintage", "Materials": "Matières", "Lettering": "Lettrage",
        "Sprays": "Vaporisateurs", "Blenders": "Estompes", "Erasers": "Gommes", "Legacy": "ProCraft (anciens)",
        "Paints": "Peintures", "Charcoal": "Fusain", "Basics": "Essentiels", "Comics": "BD", "Design": "Graphisme",
        "Grunge": "Grunge", "Street Art": "Art urbain", "Digital": "Numérique", "Creative": "Créatif",
        "Spraypaints": "Bombes de peinture", "Water": "Eau", "Earth": "Terre",
    ]

    /// Les jeux d'aquarelle et de peinture humide passent en tête de la bibliothèque.
    static func priority(_ englishName: String) -> Int {
        let lower = englishName.lowercased()
        if lower == "legacy" { return 4 }
        if lower.contains("water") { return 0 }
        if lower.contains("wet") || lower.contains("gouache") || lower.contains("ink") { return 1 }
        if lower.contains("paint") || lower.contains("oil") || lower.contains("acrylic") { return 2 }
        return 3
    }

    /// Les jeux livrés, dans l'ordre de la bibliothèque (lu dans `procraft-sets.tsv` : fichier, nom, nombre).
    static let sets: [BrushSetFile] = {
        guard let index = Bundle.main.url(forResource: "procraft-sets", withExtension: "tsv"),
              let text = try? String(contentsOf: index, encoding: .utf8) else { return [] }
        var seen: [String: Int] = [:]
        let rows: [(file: String, english: String, count: Int)] = text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count >= 3, let count = Int(parts[2]), count > 0 else { return nil }
            return (parts[0], parts[1], count)
        }
        return rows.enumerated().sorted { a, b in
            let pa = priority(a.element.english), pb = priority(b.element.english)
            return pa != pb ? pa < pb : a.offset < b.offset
        }
        .compactMap { item -> BrushSetFile? in
            let (file, english, count) = item.element
            let base = (file as NSString).deletingPathExtension
            guard let url = Bundle.main.url(forResource: base, withExtension: "brushset") else { return nil }
            var name = frenchNames[english] ?? english
            // Deux jeux du même nom (un ancien et un nouveau) : numérotés.
            seen[name, default: 0] += 1
            if let n = seen[name], n > 1 { name += " \(n)" }
            return BrushSetFile(id: "procraft/\(base)", name: name, url: url, count: count)
        }
    }()

    private static var cache: [String: [BrushPreset]] = [:]

    /// Les pinceaux d'un jeu (lus une fois).
    static func brushes(of set: BrushSetFile) -> [BrushPreset] {
        if let cached = cache[set.id] { return cached }
        let presets = (try? ProcreateBrushImport.read(data: Data(contentsOf: set.url), fallbackName: set.name)) ?? []
        cache[set.id] = presets
        return presets
    }
}
