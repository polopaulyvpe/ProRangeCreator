import Compression
import Foundation
import PRCore

/// Pinceau prêt à l'emploi, avec le compte rendu de ce qui a été repris ou ignoré à l'import.
public struct BrushPreset: Sendable, Identifiable {
    public let id = UUID()
    public var name: String
    public var settings: BrushSettings
    /// Réglages d'origine repris (clé → valeur traduite).
    public var mapped: [String]
    /// Réglages d'origine présents mais non gérés par le moteur.
    public var ignored: [String]

    public init(name: String, settings: BrushSettings, mapped: [String] = [], ignored: [String] = []) {
        self.name = name
        self.settings = settings
        self.mapped = mapped
        self.ignored = ignored
    }
}

/// Lecteur ZIP minimal (méthodes « stocké » et « deflate », pas de ZIP64) : les .brush et .brushset sont des ZIP.
struct ZipArchive {
    enum Failure: Error {
        case notZip
        case unsupported(String)
        case corrupt
    }

    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localOffset: Int
    }

    let bytes: [UInt8]
    let entries: [Entry]

    init(_ data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw Failure.notZip }
        // Fin du répertoire central : signature 0x06054b50, cherchée depuis la fin (commentaire ≤ 65 535 octets).
        var eocd = -1
        var i = bytes.count - 22
        while i >= max(0, bytes.count - 22 - 65_535) {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw Failure.notZip }
        var r = ByteReader(bytes, offset: eocd + 10)
        let count = Int(try r.read(UInt16.self))
        _ = try r.read(UInt32.self)
        var offset = Int(try r.read(UInt32.self))
        var list: [Entry] = []
        for _ in 0..<count {
            var e = ByteReader(bytes, offset: offset)
            guard try e.read(UInt32.self) == 0x0201_4B50 else { throw Failure.corrupt }
            e.offset += 6
            let method = try e.read(UInt16.self)
            e.offset += 8
            let compressed = Int(try e.read(UInt32.self))
            let uncompressed = Int(try e.read(UInt32.self))
            let nameLength = Int(try e.read(UInt16.self))
            let extraLength = Int(try e.read(UInt16.self))
            let commentLength = Int(try e.read(UInt16.self))
            e.offset += 8
            let local = Int(try e.read(UInt32.self))
            let name = String(decoding: try e.readBytes(nameLength), as: UTF8.self)
            list.append(Entry(name: name, method: method, compressedSize: compressed, uncompressedSize: uncompressed, localOffset: local))
            offset = e.offset + extraLength + commentLength
        }
        entries = list
    }

    func data(_ entry: Entry) throws -> [UInt8] {
        var r = ByteReader(bytes, offset: entry.localOffset)
        guard try r.read(UInt32.self) == 0x0403_4B50 else { throw Failure.corrupt }
        r.offset = entry.localOffset + 26
        let nameLength = Int(try r.read(UInt16.self))
        let extraLength = Int(try r.read(UInt16.self))
        r.offset += nameLength + extraLength
        let payload = try r.readBytes(entry.compressedSize)
        switch entry.method {
        case 0:
            return payload
        case 8:
            guard entry.uncompressedSize > 0 else { return [] }
            var out = [UInt8](repeating: 0, count: entry.uncompressedSize)
            let written = payload.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    compression_decode_buffer(dst.baseAddress!, entry.uncompressedSize, src.baseAddress!, payload.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.uncompressedSize else { throw Failure.corrupt }
            return out
        default:
            throw Failure.unsupported("méthode \(entry.method)")
        }
    }
}

/// Formes et grains depuis une image (PNG ou tout format lisible par `ImageDecoder`).
public enum BrushTextureImport {
    /// Valeur = luminance encodée × alpha ; si l'image a de la transparence, c'est l'alpha qui fait la forme.
    public static func texture(from image: ImportedImage, name: String, invert: Bool = false) -> BrushTexture {
        let usesAlpha = image.pixels.contains { $0.w < 0.99 }
        let gray = image.pixels.map { p -> Float in
            if usesAlpha { return p.w }
            let luminance = 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z
            return ColorTransfer.toEncoded(max(0, luminance))
        }
        return BrushTexture.make(name: name, gray: gray, width: image.width, height: image.height, invert: invert)
    }
}

/// Import au mieux des pinceaux Procreate (.brush : un pinceau ; .brushset : plusieurs).
/// Chaque pinceau est un dossier avec `Brush.archive` (plist NSKeyedArchiver), `Shape.png` et `Grain.png`.
/// Le format n'est pas documenté : on lit les réglages numériques connus, le reste est signalé comme ignoré.
public enum ProcreateBrushImport {
    public enum Failure: Error {
        case noBrush
    }

    /// Clés reconnues, avec leur traduction vers nos réglages.
    static let knownKeys: Set<String> = [
        "name", "maxSize", "minSize", "paintSize", "maxOpacity", "minOpacity", "paintOpacity", "plotSpacing",
        "dynamicsPressureSize", "dynamicsPressureOpacity", "shapeRotation", "textureScale", "grainScale",
        "textureDepth", "grainDepth", "shapeOrientation", "hardness", "plotJitter",
    ]

    public static func read(_ url: URL) throws -> [BrushPreset] {
        try read(data: Data(contentsOf: url), fallbackName: url.deletingPathExtension().lastPathComponent)
    }

    public static func read(data: Data, fallbackName: String) throws -> [BrushPreset] {
        let zip = try ZipArchive(data)
        // Un dossier par pinceau : celui de chaque Brush.archive ("" pour un .brush à plat).
        // Un pinceau Procreate garde aussi sa copie de réinitialisation (dossier « Reset ») : ce n'est pas un autre pinceau.
        let archives = zip.entries.filter { entry in
            let components = entry.name.split(separator: "/").map { $0.lowercased() }
            return components.last == "brush.archive" && !components.contains("reset") && !components.contains("__macosx")
        }
        guard !archives.isEmpty else { throw Failure.noBrush }
        return try archives.map { archive in
            let folder = (archive.name as NSString).deletingLastPathComponent
            func image(_ base: String) -> ImportedImage? {
                guard let entry = zip.entries.first(where: { e in
                    (e.name as NSString).deletingLastPathComponent == folder
                        && (e.name as NSString).lastPathComponent.lowercased() == base
                }), let bytes = try? zip.data(entry) else { return nil }
                return try? ImageDecoder.decode(data: Data(bytes))
            }
            let plist = try zip.data(archive)
            var preset = parseArchive(Data(plist), fallbackName: archives.count == 1 ? fallbackName : folder)
            if let shape = image("shape.png") {
                preset.settings.shape = BrushTextureImport.texture(from: shape, name: "\(preset.name) — forme")
                preset.mapped.append("Shape.png → forme")
            }
            if let grain = image("grain.png") {
                preset.settings.grain = BrushTextureImport.texture(from: grain, name: "\(preset.name) — grain")
                preset.mapped.append("Grain.png → grain")
            }
            return preset
        }
    }

    /// Lit les réglages numériques de l'objet racine de l'archive (le dictionnaire qui porte le plus de clés connues).
    static func parseArchive(_ data: Data, fallbackName: String) -> BrushPreset {
        var settings = BrushSettings.defaultBrush
        var mapped: [String] = []
        var ignored: [String] = []
        var name = fallbackName
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = root["$objects"] as? [Any] else {
            return BrushPreset(name: name, settings: settings, ignored: ["Brush.archive illisible"])
        }
        let dictionaries = objects.compactMap { $0 as? [String: Any] }
        guard let brush = dictionaries.max(by: { a, b in
            a.keys.filter(knownKeys.contains).count < b.keys.filter(knownKeys.contains).count
        }) else {
            return BrushPreset(name: name, settings: settings, ignored: ["aucun réglage trouvé"])
        }
        func number(_ key: String) -> Double? { (brush[key] as? NSNumber)?.doubleValue }

        // L'index 0 de $objects est « $null » : un nom absent, pas un nom.
        if let reference = brush["name"], let index = uidIndex(reference), index > 0, index < objects.count,
           let text = objects[index] as? String, !text.isEmpty, text != "$null" {
            name = text
        } else if let text = brush["name"] as? String, !text.isEmpty {
            name = text
        }
        if let size = number("maxSize") ?? number("paintSize") {
            settings.radiusDegrees = min(30, max(0.3, 0.3 + size * 20))
            mapped.append("taille max \(fmt(size)) → rayon \(fmt(settings.radiusDegrees))°")
        }
        if let minimum = number("minSize") {
            settings.minimumSize = min(1, max(0, minimum))
            mapped.append("taille min → \(fmt(settings.minimumSize))")
        }
        if let opacity = number("maxOpacity") ?? number("paintOpacity") {
            settings.opacity = min(1, max(0.02, opacity))
            mapped.append("opacité → \(fmt(settings.opacity))")
        }
        if let spacing = number("plotSpacing") {
            // Procreate : fraction du diamètre ; ici : fraction du rayon.
            settings.spacing = min(4, max(0.02, spacing * 2))
            mapped.append("espacement → \(fmt(settings.spacing)) rayon")
        }
        if let pressure = number("dynamicsPressureSize") {
            settings.pressureAffectsSize = pressure > 0.05
            mapped.append("pression → taille : \(settings.pressureAffectsSize ? "oui" : "non")")
        }
        if let pressure = number("dynamicsPressureOpacity") {
            settings.pressureAffectsOpacity = pressure > 0.05
            mapped.append("pression → opacité : \(settings.pressureAffectsOpacity ? "oui" : "non")")
        }
        if let rotation = number("shapeRotation") {
            settings.shapeRotationDegrees = abs(rotation) <= 1 ? rotation * 360 : rotation
            mapped.append("rotation de la forme → \(fmt(settings.shapeRotationDegrees))°")
        }
        if let orientation = number("shapeOrientation") {
            settings.followStroke = orientation > 0.5
            mapped.append("forme qui suit le trait : \(settings.followStroke ? "oui" : "non")")
        }
        if let scale = number("textureScale") ?? number("grainScale") {
            settings.grainScaleDegrees = min(30, max(0.2, 0.5 + scale * 10))
            mapped.append("échelle du grain → \(fmt(settings.grainScaleDegrees))°")
        }
        if let depth = number("textureDepth") ?? number("grainDepth") {
            settings.grainDepth = min(1, max(0, depth))
            mapped.append("profondeur du grain → \(fmt(settings.grainDepth))")
        }
        if let hardness = number("hardness") {
            settings.hardness = min(1, max(0, hardness))
            mapped.append("dureté → \(fmt(settings.hardness))")
        }
        for key in brush.keys.sorted() where !knownKeys.contains(key) && !key.hasPrefix("$") {
            ignored.append(key)
        }
        return BrushPreset(name: name, settings: settings, mapped: mapped, ignored: ignored)
    }

    /// Index d'une référence NSKeyedArchiver (CFKeyedArchiverUID, dont seule la description expose la valeur).
    static func uidIndex(_ value: Any) -> Int? {
        let description = String(describing: value)
        guard description.contains("UID"), let range = description.range(of: #"value = (\d+)"#, options: .regularExpression) else {
            return nil
        }
        return Int(description[range].split(separator: " ").last ?? "")
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
}

/// Format natif `.prbrush` : JSON, formes et grains en octets (niveaux de gris 8 bits) encodés en base64.
public enum NativeBrushFile {
    struct Texture: Codable {
        var name: String
        var size: Int
        var values: Data
    }

    struct File: Codable {
        var version = 1
        var name: String
        var radiusDegrees: Double
        var opacity: Double
        var hardness: Double
        var spacing: Double
        var pressureAffectsSize: Bool
        var pressureAffectsOpacity: Bool
        var minimumSize: Double
        var shapeRotationDegrees: Double
        var followStroke: Bool
        var grainScaleDegrees: Double
        var grainDepth: Double
        var shape: Texture?
        var grain: Texture?
    }

    public enum Failure: Error {
        case unsupportedVersion(Int)
    }

    static func encode(_ texture: BrushTexture?) -> Texture? {
        texture.map { t in Texture(name: t.name, size: t.size, values: Data(t.values.map { UInt8(min(1, max(0, $0)) * 255 + 0.5) })) }
    }

    static func decode(_ texture: Texture?) -> BrushTexture? {
        guard let texture, texture.size > 0, texture.values.count == texture.size * texture.size else { return nil }
        return BrushTexture(name: texture.name, size: texture.size, values: texture.values.map { Float($0) / 255 })
    }

    public static func data(_ preset: BrushPreset) throws -> Data {
        let s = preset.settings
        let file = File(name: preset.name, radiusDegrees: s.radiusDegrees, opacity: s.opacity, hardness: s.hardness, spacing: s.spacing,
                        pressureAffectsSize: s.pressureAffectsSize, pressureAffectsOpacity: s.pressureAffectsOpacity,
                        minimumSize: s.minimumSize, shapeRotationDegrees: s.shapeRotationDegrees, followStroke: s.followStroke,
                        grainScaleDegrees: s.grainScaleDegrees, grainDepth: s.grainDepth,
                        shape: encode(s.shape), grain: encode(s.grain))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(file)
    }

    public static func preset(from data: Data) throws -> BrushPreset {
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.version == 1 else { throw Failure.unsupportedVersion(file.version) }
        var s = BrushSettings(radiusDegrees: file.radiusDegrees, opacity: file.opacity, hardness: file.hardness, spacing: file.spacing,
                              pressureAffectsSize: file.pressureAffectsSize, pressureAffectsOpacity: file.pressureAffectsOpacity,
                              minimumSize: file.minimumSize)
        s.shapeRotationDegrees = file.shapeRotationDegrees
        s.followStroke = file.followStroke
        s.grainScaleDegrees = file.grainScaleDegrees
        s.grainDepth = file.grainDepth
        s.shape = decode(file.shape)
        s.grain = decode(file.grain)
        return BrushPreset(name: file.name, settings: s)
    }
}
