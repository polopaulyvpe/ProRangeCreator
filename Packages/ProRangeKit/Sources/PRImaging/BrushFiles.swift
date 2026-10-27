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

    /// Clés reconnues (noms relevés dans de vrais fichiers Procreate, version 4 du format), avec leur traduction.
    static let knownKeys: Set<String> = [
        "name", "maxSize", "minSize", "maxOpacity", "plotSpacing", "plotSpacingJitter", "plotJitter",
        "dynamicsJitterSize", "dynamicsJitterOpacity", "shapeScatter", "shapeFlipXJitter", "shapeFlipYJitter",
        "shapeAngle", "shapeRotation", "dynamicsPressureSize", "dynamicsPressureOpacity", "textureScale",
        "grainDepth", "textureDepth", "bundledShapePath", "bundledGrainPath",
        "pencilTaperStartLength", "taperStartLength", "pencilTaperSize", "taperSize", "pencilTaperOpacity", "taperOpacity",
        "shapeRoundness", "shapeCount", "shapeCountJitter", "shapeRandomise", "textureMovement", "textureRotation",
        "grainDepthMinimum", "grainDepthJitter", "textureOffsetJitter", "textureContrast", "textureBrightness", "textureInverted",
        "dynamicsSpeedSize", "dynamicsSpeedOpacity", "dynamicsTiltOpacity", "dynamicsTiltSize", "dynamicsTiltAngle", "minOpacity",
        "authorName",
    ]

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
        /// Chaîne directe ou référencée ; nil pour « $null ».
        func string(_ key: String) -> String? {
            var text = brush[key] as? String
            if text == nil, let reference = brush[key], let index = uidIndex(reference), index > 0, index < objects.count {
                text = objects[index] as? String
            }
            guard let text, !text.isEmpty, text != "$null" else { return nil }
            return text
        }

        if let text = string("name") { name = text }
        if let size = number("maxSize") {
            settings.radiusDegrees = min(30, max(0.3, 0.3 + size * 6))
            mapped.append("taille max → rayon \(fmt(settings.radiusDegrees))°")
        }
        if let minimum = number("minSize") {
            settings.minimumSize = min(1, max(0, minimum))
            mapped.append("taille min → \(fmt(settings.minimumSize))")
        }
        if let opacity = number("maxOpacity") {
            settings.opacity = min(1, max(0.02, opacity))
            mapped.append("opacité → \(fmt(settings.opacity))")
        }
        if let spacing = number("plotSpacing") {
            // Procreate : fraction du diamètre ; ici : fraction du rayon.
            settings.spacing = min(4, max(0.02, spacing * 2))
            mapped.append("espacement → \(fmt(settings.spacing)) rayon")
        }
        if let jitter = number("plotSpacingJitter"), jitter > 0 {
            settings.spacingJitter = min(1, jitter)
            mapped.append("variation d'espacement → \(pct(jitter))")
        }
        if let jitter = number("plotJitter"), jitter > 0 {
            settings.scatter = min(2, jitter)
            mapped.append("dispersion → \(pct(jitter))")
        }
        if let jitter = number("dynamicsJitterSize"), jitter > 0 {
            settings.sizeJitter = min(1, jitter)
            mapped.append("variation de taille → \(pct(jitter))")
        }
        if let jitter = number("dynamicsJitterOpacity"), jitter > 0 {
            settings.opacityJitter = min(1, jitter)
            mapped.append("variation d'opacité → \(pct(jitter))")
        }
        if let scatter = number("shapeScatter"), scatter > 0 {
            settings.rotationJitter = min(.pi, scatter * .pi / 2)
            mapped.append("rotation aléatoire → ±\(Int(settings.rotationJitter * 180 / .pi))°")
        }
        if (brush["shapeFlipXJitter"] as? Bool) == true || (brush["shapeFlipYJitter"] as? Bool) == true {
            settings.randomFlip = true
            mapped.append("retournement aléatoire")
        }
        if let angle = number("shapeAngle") {
            settings.shapeRotationDegrees = angle * 180 / .pi
        }
        if let rotation = number("shapeRotation") {
            settings.followStroke = abs(rotation) >= 0.5
            if settings.followStroke { mapped.append("forme qui suit le trait") }
        }
        if let pressure = number("dynamicsPressureSize") {
            settings.pressureAffectsSize = pressure > 0.01
            settings.pressureSizeAmount = min(1, max(0, pressure))
            mapped.append("pression → taille \(pct(pressure))")
        }
        if let pressure = number("dynamicsPressureOpacity") {
            settings.pressureAffectsOpacity = pressure > 0.01
            settings.pressureOpacityAmount = min(1, max(0, pressure))
            mapped.append("pression → opacité \(pct(pressure))")
        }
        // Effilement : celui du Pencil s'il est réglé, sinon celui du doigt ; longueur 0…1 → 0…10 diamètres.
        let taperLength = [number("pencilTaperStartLength"), number("taperStartLength")].compactMap { $0 }.first { $0 > 0 } ?? 0
        if taperLength > 0 {
            settings.taperStartLength = taperLength * 10
            settings.taperSize = min(1, max(0, number("pencilTaperSize") ?? number("taperSize") ?? 1))
            settings.taperOpacity = min(1, max(0, number("pencilTaperOpacity") ?? number("taperOpacity") ?? 0))
            mapped.append("effilement → \(fmt(settings.taperStartLength)) diamètres")
        }
        if let roundness = number("shapeRoundness") {
            settings.shapeRoundness = min(1, max(0.05, roundness))
            mapped.append("rondeur → \(pct(settings.shapeRoundness))")
        }
        if let count = number("shapeCount"), count > 0 {
            settings.stampCount = count <= 1 ? 1 + Int((count * 15).rounded()) : min(16, Int(count))
            mapped.append("nombre de tampons → \(settings.stampCount)")
        }
        if let jitter = number("shapeCountJitter"), jitter > 0 { settings.stampCountJitter = min(1, jitter) }
        if (brush["shapeRandomise"] as? Bool) == true {
            settings.randomizeRotation = true
            mapped.append("angle de départ aléatoire")
        }
        if let movement = number("textureMovement") {
            settings.grainMoving = movement > 0.5
            mapped.append("grain \(settings.grainMoving ? "mobile" : "texturé")")
        }
        if let rotation = number("textureRotation"), rotation != 0 {
            settings.grainRotationDegrees = abs(rotation) <= 1 ? rotation * 180 : rotation
        }
        if let minimum = number("grainDepthMinimum") { settings.grainDepthMinimum = min(1, max(0, minimum)) }
        if let jitter = number("grainDepthJitter") { settings.grainDepthJitter = min(1, max(0, jitter)) }
        if (brush["textureOffsetJitter"] as? Bool) == true { settings.grainOffsetJitter = true }
        if let contrast = number("textureContrast") {
            settings.grainContrast = max(-1, min(1, contrast))
            mapped.append("contraste du grain → \(pct(contrast))")
        }
        if let brightness = number("textureBrightness") {
            settings.grainBrightness = max(-1, min(1, brightness))
            mapped.append("luminosité du grain → \(pct(brightness))")
        }
        if (brush["textureInverted"] as? Bool) == true { settings.grainInverted = true }
        if let speed = number("dynamicsSpeedSize"), speed != 0 {
            settings.speedSize = max(-1, min(1, speed))
            mapped.append("vitesse → taille \(pct(speed))")
        }
        if let speed = number("dynamicsSpeedOpacity"), speed != 0 {
            settings.speedOpacity = max(-1, min(1, speed))
            mapped.append("vitesse → opacité \(pct(speed))")
        }
        if let tilt = number("dynamicsTiltOpacity"), tilt > 0 {
            settings.tiltOpacity = min(1, tilt)
            mapped.append("inclinaison → opacité \(pct(tilt))")
        }
        if let tilt = number("dynamicsTiltSize"), tilt > 0 { settings.tiltSize = min(2, tilt) }
        if let angle = number("dynamicsTiltAngle") { settings.tiltAngleDegrees = min(89, max(0, angle * 90)) }
        if let minimum = number("minOpacity") { settings.minOpacity = min(1, max(0.02, minimum)) }
        if let scale = number("textureScale") {
            settings.grainScaleDegrees = min(30, max(0.2, 3 * scale))
            mapped.append("échelle du grain → \(fmt(settings.grainScaleDegrees))°")
        }
        if let depth = number("grainDepth") ?? number("textureDepth") {
            settings.grainDepth = min(1, max(0, depth))
            mapped.append("profondeur du grain → \(pct(depth))")
        }
        // Textures internes de Procreate : nommées dans le fichier mais pas incluses ; remplacées par des substituts.
        if let path = string("bundledShapePath") {
            settings.shape = BuiltInBrushes.substituteShape
            ignored.append("forme « \((path as NSString).lastPathComponent) » interne à Procreate, absente du fichier : substitut granuleux (importe une image pour la remplacer)")
        }
        if let path = string("bundledGrainPath") {
            settings.grainSource = BuiltInBrushes.substituteGrain
            ignored.append("grain « \((path as NSString).lastPathComponent) » interne à Procreate, absent du fichier : substitut (importe une image pour le remplacer)")
        }
        let others = brush.keys.filter { !knownKeys.contains($0) && !$0.hasPrefix("$") }.count
        if others > 0 {
            ignored.append("\(others) autres réglages non gérés (mélange humide, dynamique de couleur, inclinaison, effilement, rendu…)")
        }
        settings.name = name
        settings.author = string("authorName") ?? ""
        // Grain dérivé de l'image importée et des réglages de contraste, luminosité, inversion.
        settings.refreshGrain()
        return BrushPreset(name: name, settings: settings, mapped: mapped, ignored: ignored)
    }

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
                && !isSecondary(components)
        }
        let hasSecondary = zip.entries.contains { isSecondary($0.name.split(separator: "/").map { $0.lowercased() }) }
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
            if hasSecondary { preset.ignored.append("pinceau double : seul le pinceau principal est importé") }
            if let shape = image("shape.png") {
                preset.settings.shape = BrushTextureImport.texture(from: shape, name: "\(preset.name) — forme")
                preset.mapped.append("Shape.png → forme")
            }
            if let grain = image("grain.png") {
                preset.settings.grainSource = BrushTextureImport.texture(from: grain, name: "\(preset.name) — grain")
                preset.settings.refreshGrain()
                preset.mapped.append("Grain.png → grain")
            }
            return preset
        }
    }

    /// Pinceau secondaire d'un pinceau double (dossier « Sub01 »…), que le moteur ne sait pas combiner.
    static func isSecondary(_ components: [String]) -> Bool {
        guard components.count >= 2 else { return false }
        let folder = components[components.count - 2]
        return folder.hasPrefix("sub") && folder.dropFirst(3).allSatisfy(\.isNumber) && folder.count > 3
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
    private static func pct(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }
}
/// Format natif `.prbrush` : JSON, formes et grains en octets (niveaux de gris 8 bits) encodés en base64.
/// Les réglages ajoutés après la version 1 sont rangés dans `values` et `flags` (nom → valeur) : un fichier ancien
/// les laisse à leur valeur par défaut, un réglage futur n'empêche pas de relire le fichier.
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
        var spacingJitter: Double?
        var scatter: Double?
        var sizeJitter: Double?
        var opacityJitter: Double?
        var rotationJitter: Double?
        var randomFlip: Bool?
        var author: String?
        var grainSource: Texture?
        var values: [String: Double]?
        var flags: [String: Bool]?
    }

    public enum Failure: Error {
        case unsupportedVersion(Int)
    }

    /// Réglages numériques de l'Atelier, par nom.
    static var numericKeys: [(String, WritableKeyPath<BrushSettings, Double>)] { [
        ("taperStartLength", \.taperStartLength), ("taperSize", \.taperSize), ("taperOpacity", \.taperOpacity),
        ("shapeRoundness", \.shapeRoundness), ("stampCountJitter", \.stampCountJitter),
        ("grainRotationDegrees", \.grainRotationDegrees), ("grainDepthMinimum", \.grainDepthMinimum),
        ("grainDepthJitter", \.grainDepthJitter), ("grainContrast", \.grainContrast), ("grainBrightness", \.grainBrightness),
        ("speedSize", \.speedSize), ("speedOpacity", \.speedOpacity),
        ("pressureSizeAmount", \.pressureSizeAmount), ("pressureOpacityAmount", \.pressureOpacityAmount),
        ("tiltOpacity", \.tiltOpacity), ("tiltSize", \.tiltSize), ("tiltAngleDegrees", \.tiltAngleDegrees),
        ("maxSizeDegrees", \.maxSizeDegrees), ("minSizeDegrees", \.minSizeDegrees),
        ("maxOpacity", \.maxOpacity), ("minOpacity", \.minOpacity),
    ] }

    /// Réglages oui / non de l'Atelier, par nom.
    static var flagKeys: [(String, WritableKeyPath<BrushSettings, Bool>)] { [
        ("randomizeRotation", \.randomizeRotation), ("grainMoving", \.grainMoving),
        ("grainOffsetJitter", \.grainOffsetJitter), ("grainInverted", \.grainInverted),
    ] }

    static func encode(_ texture: BrushTexture?) -> Texture? {
        texture.map { t in Texture(name: t.name, size: t.size, values: Data(t.values.map { UInt8(min(1, max(0, $0)) * 255 + 0.5) })) }
    }

    static func decode(_ texture: Texture?) -> BrushTexture? {
        guard let texture, texture.size > 0, texture.values.count == texture.size * texture.size else { return nil }
        return BrushTexture(name: texture.name, size: texture.size, values: texture.values.map { Float($0) / 255 })
    }

    public static func data(_ preset: BrushPreset) throws -> Data {
        let s = preset.settings
        var values: [String: Double] = [:]
        for (key, path) in numericKeys { values[key] = s[keyPath: path] }
        values["stampCount"] = Double(s.stampCount)
        var flags: [String: Bool] = [:]
        for (key, path) in flagKeys { flags[key] = s[keyPath: path] }
        let file = File(name: preset.name, radiusDegrees: s.radiusDegrees, opacity: s.opacity, hardness: s.hardness, spacing: s.spacing,
                        pressureAffectsSize: s.pressureAffectsSize, pressureAffectsOpacity: s.pressureAffectsOpacity,
                        minimumSize: s.minimumSize, shapeRotationDegrees: s.shapeRotationDegrees, followStroke: s.followStroke,
                        grainScaleDegrees: s.grainScaleDegrees, grainDepth: s.grainDepth,
                        shape: encode(s.shape), grain: encode(s.grain),
                        spacingJitter: s.spacingJitter, scatter: s.scatter, sizeJitter: s.sizeJitter,
                        opacityJitter: s.opacityJitter, rotationJitter: s.rotationJitter, randomFlip: s.randomFlip,
                        author: s.author, grainSource: encode(s.grainSource), values: values, flags: flags)
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
        s.name = file.name
        s.author = file.author ?? ""
        s.shapeRotationDegrees = file.shapeRotationDegrees
        s.followStroke = file.followStroke
        s.grainScaleDegrees = file.grainScaleDegrees
        s.grainDepth = file.grainDepth
        s.shape = decode(file.shape)
        s.grain = decode(file.grain)
        s.grainSource = decode(file.grainSource)
        s.spacingJitter = file.spacingJitter ?? 0
        s.scatter = file.scatter ?? 0
        s.sizeJitter = file.sizeJitter ?? 0
        s.opacityJitter = file.opacityJitter ?? 0
        s.rotationJitter = file.rotationJitter ?? 0
        s.randomFlip = file.randomFlip ?? false
        for (key, path) in numericKeys { if let v = file.values?[key] { s[keyPath: path] = v } }
        if let count = file.values?["stampCount"] { s.stampCount = max(1, min(16, Int(count))) }
        for (key, path) in flagKeys { if let v = file.flags?[key] { s[keyPath: path] = v } }
        return BrushPreset(name: file.name, settings: s)
    }
}
