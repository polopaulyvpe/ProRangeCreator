import Compression
import Foundation
import PRCore

// Pinceaux d'autres logiciels : Photoshop (.abr), GIMP (.gbr, .gih, .vbr) et Krita (.kpp, .bundle).
// Les formats sont lus d'après le moteur de ProCraft (github.com/artcraft-android/procraft, `crates/engine/src/abr.rs`,
// `gbr.rs`, `krita.rs`, MIT ou Apache-2.0, voir NOTICE.md). On en garde la forme (l'image du tampon, blanc = peinture),
// le nom, l'espacement, l'angle, la rondeur et la dureté ; le reste de leurs réglages est signalé comme ignoré.

/// Lecture grand-boutiste (Photoshop, GIMP), nil après la fin.
struct BigEndianReader {
    let bytes: [UInt8]
    var at = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }
    init<S: Sequence>(_ slice: S) where S.Element == UInt8 { self.bytes = Array(slice) }

    var remaining: Int { max(0, bytes.count - at) }

    mutating func take(_ n: Int) -> [UInt8]? {
        guard n >= 0, at + n <= bytes.count else { return nil }
        defer { at += n }
        return Array(bytes[at..<(at + n)])
    }

    mutating func u8() -> UInt8? { take(1)?.first }

    mutating func u16() -> UInt16? {
        guard let b = take(2) else { return nil }
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }

    mutating func u32() -> UInt32? {
        guard let b = take(4) else { return nil }
        return b.reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func i32() -> Int32? { u32().map { Int32(bitPattern: $0) } }

    mutating func f64() -> Double? {
        guard let b = take(8) else { return nil }
        return Double(bitPattern: b.reduce(0) { $0 << 8 | UInt64($1) })
    }

    /// Clé de descripteur Photoshop : sa longueur, puis ses lettres (longueur 0 : quatre).
    mutating func key() -> String? {
        guard let n = u32(), let b = take(n == 0 ? 4 : Int(n)) else { return nil }
        return String(decoding: b, as: UTF8.self)
    }

    /// Nombre d'unités UTF-16, puis les unités (nul final retiré).
    mutating func unicode() -> String? {
        guard let n = u32(), n < 1 << 20, let b = take(Int(n) * 2) else { return nil }
        let units = stride(from: 0, to: b.count, by: 2).map { UInt16(b[$0]) << 8 | UInt16(b[$0 + 1]) }
        return String(decoding: units, as: UTF16.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }
}

/// Image en niveaux de gris d'un tampon (0 = rien, 255 = peinture pleine).
struct GrayTip {
    var name: String
    var width: Int
    var height: Int
    var pixels: [UInt8]
    /// Espacement en part du diamètre, si le fichier le donne.
    var spacing: Double?
}

public enum ForeignBrushImport {
    public enum Failure: Error, CustomStringConvertible {
        case unreadable(String)

        public var description: String {
            switch self {
            case .unreadable(let what): "fichier \(what) illisible ou sans pinceau"
            }
        }
    }

    static let mostSide = 5000

    /// Extensions reconnues.
    public static let extensions: Set<String> = ["abr", "gbr", "gih", "vbr", "kpp", "bundle"]

    public static func read(_ url: URL) throws -> [BrushPreset] {
        try read(data: Data(contentsOf: url), fileName: url.lastPathComponent)
    }

    public static func read(data: Data, fileName: String) throws -> [BrushPreset] {
        let bytes = [UInt8](data)
        let ext = (fileName as NSString).pathExtension.lowercased()
        let base = (fileName as NSString).deletingPathExtension
        let presets: [BrushPreset]
        switch ext {
        case "abr": presets = abr(bytes)
        case "gbr": presets = gimpBrush(bytes).map { [preset($0.tip, source: "GIMP", fallbackName: base)] } ?? []
        case "gih": presets = gimpPipe(bytes).first.map { [preset($0, source: "GIMP (pipe, première image)", fallbackName: base)] } ?? []
        case "vbr": presets = gimpGenerated(bytes, fallbackName: base).map { [$0] } ?? []
        case "kpp": presets = krita(bytes, fallbackName: base, resources: { _ in nil }).map { [$0] } ?? []
        case "bundle": presets = kritaBundle(data)
        default: presets = []
        }
        guard !presets.isEmpty else { throw Failure.unreadable(ext.uppercased()) }
        return presets
    }

    // MARK: - Pinceau commun

    /// Forme carrée (l'image est centrée dans un carré, sans rien rogner).
    static func texture(_ tip: GrayTip) -> BrushTexture {
        let side = max(tip.width, tip.height)
        var gray = [Float](repeating: 0, count: side * side)
        let x0 = (side - tip.width) / 2, y0 = (side - tip.height) / 2
        for y in 0..<tip.height {
            for x in 0..<tip.width { gray[(y0 + y) * side + x0 + x] = Float(tip.pixels[y * tip.width + x]) / 255 }
        }
        return BrushTexture.make(name: tip.name, gray: gray, width: side, height: side)
    }

    /// Pinceau d'une forme image, avec son espacement (part du diamètre : notre espacement est en part du rayon).
    static func preset(_ tip: GrayTip, source: String, fallbackName: String, angle: Double = 0, roundness: Double = 1) -> BrushPreset {
        var settings = BrushSettings()
        let name = tip.name.trimmingCharacters(in: .whitespaces).isEmpty ? fallbackName : tip.name
        settings.name = name
        settings.shape = texture(tip)
        settings.hardness = 1
        var mapped = ["forme \(source) \(tip.width) × \(tip.height)"]
        if let spacing = tip.spacing, spacing > 0 {
            settings.spacing = min(4, spacing * 2)
            mapped.append("espacement \(Int((spacing * 100).rounded())) % du diamètre")
        }
        if angle != 0 {
            settings.shapeRotationDegrees = angle * 180 / .pi
            mapped.append("angle \(Int(settings.shapeRotationDegrees.rounded()))°")
        }
        if roundness < 1 {
            settings.shapeRoundness = max(0.05, roundness)
            mapped.append("rondeur \(Int((roundness * 100).rounded())) %")
        }
        return BrushPreset(name: name, settings: settings, mapped: mapped)
    }

    /// Pinceau rond calculé (sans image) : dureté, angle et rondeur.
    static func roundPreset(name: String, hardness: Double, spacing: Double?, angle: Double, roundness: Double,
                            source: String, ignored: [String] = []) -> BrushPreset {
        var settings = BrushSettings()
        settings.name = name
        settings.hardness = min(1, max(0, hardness))
        var mapped = ["rond \(source), dureté \(Int((settings.hardness * 100).rounded())) %"]
        if let spacing, spacing > 0 {
            settings.spacing = min(4, spacing * 2)
            mapped.append("espacement \(Int((spacing * 100).rounded())) % du diamètre")
        }
        if roundness < 0.999 {
            // Un rond écrasé n'existe qu'avec une forme : on dessine le disque.
            let side = 128
            var gray = [Float](repeating: 0, count: side * side)
            for y in 0..<side {
                for x in 0..<side {
                    let px = (Double(x) + 0.5) / Double(side) * 2 - 1, py = (Double(y) + 0.5) / Double(side) * 2 - 1
                    let r = (px * px + py * py).squareRoot()
                    let inner = settings.hardness
                    gray[y * side + x] = Float(r >= 1 ? 0 : (r <= inner ? 1 : 1 - (r - inner) / max(1e-6, 1 - inner)))
                }
            }
            settings.shape = BrushTexture.make(name: name, gray: gray, width: side, height: side)
            settings.shapeRoundness = max(0.05, roundness)
            settings.shapeRotationDegrees = angle * 180 / .pi
            mapped.append("rondeur \(Int((roundness * 100).rounded())) %, angle \(Int(settings.shapeRotationDegrees.rounded()))°")
        }
        return BrushPreset(name: name, settings: settings, mapped: mapped, ignored: ignored)
    }

    // MARK: - GIMP

    /// Un pinceau GIMP (.gbr, versions 1 à 3) et la taille qu'il occupe dans le fichier.
    static func gimpBrush(_ bytes: [UInt8], at start: Int = 0) -> (tip: GrayTip, length: Int)? {
        var r = BigEndianReader(bytes)
        r.at = start
        guard let header = r.u32().map(Int.init), let version = r.u32(), let width = r.u32().map(Int.init),
              let height = r.u32().map(Int.init), let depth = r.u32().map(Int.init) else { return nil }
        var spacing: Double?
        let fixed: Int
        switch version {
        case 1 where header >= 20:
            fixed = 20
        case 2, 3:
            guard header >= 28, r.take(4) == Array("GIMP".utf8), let s = r.u32() else { return nil }
            spacing = s > 0 ? Double(s) / 100 : nil
            fixed = 28
        default:
            return nil
        }
        guard (1...mostSide).contains(width), (1...mostSide).contains(height), depth == 1 || depth == 4,
              start + header <= bytes.count else { return nil }
        let nameBytes = bytes[(start + fixed)..<(start + header)].prefix { $0 != 0 }
        let name = String(decoding: nameBytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        let size = width * height * depth
        guard start + header + size <= bytes.count else { return nil }
        let image = bytes[(start + header)..<(start + header + size)]
        // Niveaux de gris : la valeur est la couverture ; en couleur, l'alpha.
        let pixels = depth == 1 ? Array(image) : stride(from: image.startIndex + 3, to: image.endIndex, by: 4).map { image[$0] }
        return (GrayTip(name: name, width: width, height: height, pixels: pixels, spacing: spacing), header + size)
    }

    /// Pipe GIMP (.gih) : nom, ligne de paramètres, puis les pinceaux à la suite.
    static func gimpPipe(_ bytes: [UInt8]) -> [GrayTip] {
        guard let first = bytes.firstIndex(of: 10), let second = bytes[(first + 1)...].firstIndex(of: 10) else { return [] }
        let name = String(decoding: bytes[..<first], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        let count = Int(String(decoding: bytes[(first + 1)..<second], as: UTF8.self).split(separator: " ").first ?? "") ?? 0
        var tips: [GrayTip] = []
        var at = second + 1
        for _ in 0..<min(max(count, 1), 256) {
            guard let (tip, length) = gimpBrush(bytes, at: at) else { break }
            var named = tip
            if named.name.isEmpty { named.name = name }
            tips.append(named)
            at += length
        }
        // La première image non vide.
        return tips.filter { $0.pixels.contains { $0 > 0 } } + tips.filter { !$0.pixels.contains { $0 > 0 } }
    }

    /// Pinceau GIMP calculé (.vbr) : cercle, carré ou losange.
    static func gimpGenerated(_ bytes: [UInt8], fallbackName: String) -> BrushPreset? {
        let text = String(decoding: bytes.prefix(4096), as: UTF8.self)
        var lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.makeIterator()
        guard lines.next() == "GIMP-VBR", let version = lines.next(), let name = lines.next() else { return nil }
        var shape = "circle"
        if version == "1.5" { shape = lines.next() ?? "circle" } else if version != "1.0" { return nil }
        func number() -> Double? { lines.next().flatMap(Double.init) }
        guard let spacing = number(), number() != nil else { return nil }
        let spikes = version == "1.5" ? (number() ?? 2) : 2
        guard let hardness = number(), let aspect = number(), let angle = number() else { return nil }
        var ignored: [String] = []
        if shape != "circle" || spikes != 2 { ignored.append("forme « \(shape) » à \(Int(spikes)) pointes (dessinée en rond)") }
        return roundPreset(name: name.isEmpty ? fallbackName : name, hardness: hardness, spacing: spacing / 100,
                           angle: angle * .pi / 180, roundness: 1 / min(20, max(1, aspect)), source: "GIMP", ignored: ignored)
    }

    // MARK: - Photoshop

    static func abr(_ bytes: [UInt8]) -> [BrushPreset] {
        var r = BigEndianReader(bytes)
        guard let version = r.u16() else { return [] }
        switch version {
        case 1, 2:
            return abrOld(&r, version: version).map { preset($0, source: "Photoshop", fallbackName: $0.name) }
        case 6...:
            guard bytes.count > 8, Array(bytes[4..<8]) == Array("8BIM".utf8) else { return [] }
            return abrSections(&r)
        default:
            return []
        }
    }

    /// Versions 1 et 2 : les tampons à la suite (les tampons calculés sont passés).
    static func abrOld(_ r: inout BigEndianReader, version: UInt16) -> [GrayTip] {
        guard let count = r.u16() else { return [] }
        var tips: [GrayTip] = []
        for n in 1...max(1, Int(count)) {
            guard let kind = r.u16(), let length = r.u32(), let body = r.take(Int(length)) else { break }
            guard kind == 2 else { continue }
            var b = BigEndianReader(body)
            guard b.u32() != nil, let spacing = b.u16() else { continue }
            let name = version == 2 ? (b.unicode() ?? "") : ""
            guard b.u8() != nil, b.take(8) != nil, let top = b.i32(), let left = b.i32(), let bottom = b.i32(), let right = b.i32(),
                  let depth = b.u16(), let compression = b.u8(),
                  let image = abrImage(&b, top: top, left: left, bottom: bottom, right: right, depth: depth, compression: compression)
            else { continue }
            tips.append(GrayTip(name: name.isEmpty ? "Pinceau \(n)" : name, width: image.width, height: image.height,
                                pixels: image.pixels, spacing: spacing > 0 ? Double(spacing) / 100 : nil))
        }
        return tips
    }

    /// Image d'un tampon : brute ou compressée (PackBits, longueur de chaque rangée d'abord), 8 ou 16 bits, lue en 8.
    static func abrImage(_ r: inout BigEndianReader, top: Int32, left: Int32, bottom: Int32, right: Int32, depth: UInt16,
                         compression: UInt8) -> (width: Int, height: Int, pixels: [UInt8])? {
        let w = Int(right) - Int(left), h = Int(bottom) - Int(top)
        guard (1...mostSide).contains(w), (1...mostSide).contains(h), depth == 8 || depth == 16 else { return nil }
        let sample = depth == 8 ? 1 : 2
        let row = w * sample
        var raw: [UInt8]
        switch compression {
        case 0:
            guard let b = r.take(row * h) else { return nil }
            raw = b
        case 1:
            var counts: [Int] = []
            for _ in 0..<h {
                guard let c = r.u16() else { return nil }
                counts.append(Int(c))
            }
            raw = []
            raw.reserveCapacity(row * h)
            for c in counts {
                guard let packed = r.take(c) else { return nil }
                unpackBits(packed, row: row, into: &raw)
            }
        default:
            return nil
        }
        if sample == 2 { raw = stride(from: 0, to: raw.count, by: 2).map { raw[$0] } }
        return (w, h, raw)
    }

    /// PackBits : une rangée de `row` octets ajoutée à `out` (complétée de zéros si elle est courte).
    static func unpackBits(_ packed: [UInt8], row: Int, into out: inout [UInt8]) {
        let end = out.count + row
        var i = 0
        while out.count < end, i < packed.count {
            let n = Int8(bitPattern: packed[i])
            i += 1
            if n >= 0 {
                for _ in 0...Int(n) {
                    out.append(i < packed.count ? packed[i] : 0)
                    i += 1
                }
            } else if n != -128 {
                let v = i < packed.count ? packed[i] : 0
                i += 1
                out.append(contentsOf: repeatElement(v, count: Int(-Int(n)) + 1))
            }
        }
        if out.count > end { out.removeLast(out.count - end) }
        while out.count < end { out.append(0) }
    }

    /// Version 6 et suivantes : sections « 8BIM » ; « samp » contient les tampons, « desc » les préréglages.
    static func abrSections(_ r: inout BigEndianReader) -> [BrushPreset] {
        guard let minor = r.u16() else { return [] }
        var samples: [(id: String, tip: GrayTip)] = []
        var presets: [AbrObject] = []
        while r.remaining >= 12 {
            guard r.take(4) == Array("8BIM".utf8), let key = r.take(4), let length = r.u32() else { break }
            guard let data = r.take(Int(length)) else { break }
            _ = r.take(min((4 - Int(length) % 4) % 4, r.remaining))
            switch String(decoding: key, as: UTF8.self) {
            case "samp": samples = abrSamples(data, minor: minor)
            case "desc": presets = abrPresets(data)
            default: break
            }
        }
        var out: [BrushPreset] = []
        var used = Set<String>()
        for p in presets {
            guard let tip = p.object("Brsh") else { continue }
            let name = p.text("Nm  ") ?? "Pinceau \(out.count + 1)"
            let spacing = tip.number("Spcn").map { $0 / 100 }.flatMap { $0 > 0 ? $0 : nil }
            let angle = (tip.number("Angl") ?? 0) * .pi / 180
            let roundness = tip.number("Rndn").map { $0 / 100 }.flatMap { $0 > 0 && $0 <= 1 ? $0 : nil } ?? 1
            var ignored: [String] = []
            for key in ["useScatter", "useTexture", "useDualBrush", "useColorDynamics", "usePaintDynamics"] where p.flag(key) {
                ignored.append("réglage Photoshop « \(key) »")
            }
            if let id = tip.text("sampledData") {
                guard let sample = samples.first(where: { $0.id == id }) else { continue }
                used.insert(id)
                var gray = sample.tip
                gray.name = name
                gray.spacing = spacing
                var made = preset(gray, source: "Photoshop", fallbackName: name, angle: angle, roundness: roundness)
                made.ignored = ignored
                out.append(made)
            } else {
                out.append(roundPreset(name: name, hardness: (tip.number("Hrdn") ?? 100) / 100, spacing: spacing, angle: angle,
                                       roundness: roundness, source: "Photoshop", ignored: ignored))
            }
        }
        // Tampons qu'aucun préréglage ne nomme, tels quels.
        for sample in samples where !used.contains(sample.id) {
            var tip = sample.tip
            tip.name = "Pinceau \(out.count + 1)"
            out.append(preset(tip, source: "Photoshop", fallbackName: tip.name))
        }
        return out
    }

    static func abrSamples(_ data: [UInt8], minor: UInt16) -> [(id: String, tip: GrayTip)] {
        var r = BigEndianReader(data)
        var out: [(id: String, tip: GrayTip)] = []
        while r.remaining >= 4 {
            guard let length = r.u32().map(Int.init) else { break }
            let padded = (length + 3) / 4 * 4
            guard let body = r.take(min(padded, r.remaining)) else { break }
            var b = BigEndianReader(body.prefix(length))
            guard let n = b.u8(), let idBytes = b.take(Int(n)) else { continue }
            let id = String(decoding: idBytes, as: UTF8.self)
            if minor == 1 {
                guard b.take(10) != nil, let top = b.i32(), let left = b.i32(), let bottom = b.i32(), let right = b.i32(),
                      let depth = b.u16(), let compression = b.u8(),
                      let image = abrImage(&b, top: top, left: left, bottom: bottom, right: right, depth: depth, compression: compression)
                else { continue }
                out.append((id, GrayTip(name: "", width: image.width, height: image.height, pixels: image.pixels)))
            } else {
                guard b.take(4) != nil, let image = abrFirstChannel(&b) else { continue }
                out.append((id, GrayTip(name: "", width: image.width, height: image.height, pixels: image.pixels)))
            }
        }
        return out
    }

    /// Premier canal écrit d'un tableau de canaux (version, longueur, rectangle, puis chaque canal).
    static func abrFirstChannel(_ b: inout BigEndianReader) -> (width: Int, height: Int, pixels: [UInt8])? {
        guard b.u32() != nil, b.u32() != nil, b.take(16) != nil, let count = b.u32() else { return nil }
        for _ in 0..<min(Int(count) + 2, 64) {
            guard let written = b.u32() else { return nil }
            guard written != 0 else { continue }
            guard let length = b.u32().map(Int.init) else { return nil }
            guard length != 0 else { continue }
            guard let body = b.take(length) else { return nil }
            var c = BigEndianReader(body)
            guard c.u32() != nil, let top = c.i32(), let left = c.i32(), let bottom = c.i32(), let right = c.i32(),
                  let depth = c.u16(), let compression = c.u8() else { return nil }
            return abrImage(&c, top: top, left: left, bottom: bottom, right: right, depth: depth, compression: compression)
        }
        return nil
    }

    /// Objet d'un descripteur Photoshop : sa classe et ses valeurs par clé.
    struct AbrObject {
        enum Value {
            case object(AbrObject)
            case number(Double)
            case text(String)
            case bool(Bool)
            case other
        }

        var className = ""
        var items: [(String, Value)] = []

        func value(_ key: String) -> Value? { items.first { $0.0 == key }?.1 }

        func object(_ key: String) -> AbrObject? {
            if case .object(let o) = value(key) { return o }
            return nil
        }

        func number(_ key: String) -> Double? {
            if case .number(let v) = value(key), v.isFinite { return v }
            return nil
        }

        func text(_ key: String) -> String? {
            if case .text(let s) = value(key) { return s }
            return nil
        }

        func flag(_ key: String) -> Bool {
            if case .bool(true) = value(key) { return true }
            return false
        }
    }

    static func abrPresets(_ data: [UInt8]) -> [AbrObject] {
        var r = BigEndianReader(data)
        var out: [AbrObject] = []
        guard r.u32() != nil, r.unicode() != nil, r.key() != nil, let count = r.u32() else { return out }
        for _ in 0..<min(Int(count), 4096) {
            guard let key = r.key() else { break }
            guard key == "Brsh" else {
                guard abrValue(&r, depth: 0) != nil else { break }
                continue
            }
            guard r.take(4) == Array("VlLs".utf8), let n = r.u32() else { break }
            for _ in 0..<min(Int(n), 100_000) {
                guard let value = abrValue(&r, depth: 1) else { return out }
                if case .object(let o) = value, o.className == "brushPreset" { out.append(o) }
            }
        }
        return out
    }

    static func abrObject(_ r: inout BigEndianReader, depth: Int) -> AbrObject? {
        guard depth <= 32, r.unicode() != nil, let className = r.key(), let count = r.u32() else { return nil }
        var object = AbrObject(className: className)
        for _ in 0..<min(Int(count), 100_000) {
            guard let key = r.key(), let value = abrValue(&r, depth: depth) else { return nil }
            object.items.append((key, value))
        }
        return object
    }

    static func abrValue(_ r: inout BigEndianReader, depth: Int) -> AbrObject.Value? {
        guard depth <= 32, let type = r.take(4) else { return nil }
        switch String(decoding: type, as: UTF8.self) {
        case "Objc", "GlbO":
            return abrObject(&r, depth: depth + 1).map { .object($0) }
        case "VlLs":
            guard let n = r.u32() else { return nil }
            for _ in 0..<min(Int(n), 100_000) {
                guard abrValue(&r, depth: depth + 1) != nil else { return nil }
            }
            return .other
        case "doub":
            return r.f64().map { .number($0) }
        case "UntF":
            guard r.take(4) != nil else { return nil }
            return r.f64().map { .number($0) }
        case "UnFl":
            guard r.take(4) != nil, let n = r.u32(), r.take(Int(n) * 8) != nil else { return nil }
            return .other
        case "long":
            return r.i32().map { .number(Double($0)) }
        case "comp":
            return r.take(8).map { b in .number(Double(Int64(bitPattern: b.reduce(0) { $0 << 8 | UInt64($1) }))) }
        case "bool":
            return r.u8().map { .bool($0 != 0) }
        case "TEXT":
            return r.unicode().map { .text($0) }
        case "enum":
            guard r.key() != nil, r.key() != nil else { return nil }
            return .other
        case "type", "GlbC":
            guard r.unicode() != nil, r.key() != nil else { return nil }
            return .other
        case "alis", "tdta", "Pth ":
            guard let n = r.u32(), r.take(Int(n)) != nil else { return nil }
            return .other
        case "obj ":
            return abrReference(&r) ? .other : nil
        default:
            return nil
        }
    }

    static func abrReference(_ r: inout BigEndianReader) -> Bool {
        guard let count = r.u32() else { return false }
        for _ in 0..<min(Int(count), 1000) {
            guard let form = r.take(4) else { return false }
            switch String(decoding: form, as: UTF8.self) {
            case "prop": guard r.unicode() != nil, r.key() != nil, r.key() != nil else { return false }
            case "Clss": guard r.unicode() != nil, r.key() != nil else { return false }
            case "Enmr": guard r.unicode() != nil, r.key() != nil, r.key() != nil, r.key() != nil else { return false }
            case "rele": guard r.unicode() != nil, r.key() != nil, r.i32() != nil else { return false }
            case "Idnt", "indx": guard r.u32() != nil else { return false }
            case "name": guard r.unicode() != nil, r.key() != nil, r.unicode() != nil else { return false }
            default: return false
            }
        }
        return true
    }

    // MARK: - Krita

    /// Textes d'un PNG (tEXt, zTXt, iTXt), par mot-clé.
    static func pngTexts(_ png: [UInt8]) -> [String: String] {
        guard png.count > 8, Array(png[0..<8]) == [137, 80, 78, 71, 13, 10, 26, 10] else { return [:] }
        var r = BigEndianReader(png)
        r.at = 8
        var out: [String: String] = [:]
        while r.remaining >= 12 {
            guard let length = r.u32().map(Int.init), let type = r.take(4), let data = r.take(length), r.take(4) != nil else { break }
            let kind = String(decoding: type, as: UTF8.self)
            guard ["tEXt", "zTXt", "iTXt"].contains(kind), let nul = data.firstIndex(of: 0) else {
                if kind == "IEND" { break }
                continue
            }
            let keyword = String(decoding: data[..<nul], as: UTF8.self)
            var rest = Array(data[(nul + 1)...])
            switch kind {
            case "tEXt":
                out[keyword] = String(decoding: rest, as: UTF8.self)
            case "zTXt":
                guard rest.count > 1, let text = inflate(Array(rest.dropFirst())) else { continue }
                out[keyword] = String(decoding: text, as: UTF8.self)
            default:
                // iTXt : drapeau de compression, méthode, langue et mot-clé traduit (terminés par nul), puis le texte.
                guard rest.count > 2 else { continue }
                let compressed = rest[0] == 1
                rest = Array(rest.dropFirst(2))
                for _ in 0..<2 {
                    guard let z = rest.firstIndex(of: 0) else { break }
                    rest = Array(rest[(z + 1)...])
                }
                if compressed {
                    guard let text = inflate(rest) else { continue }
                    rest = text
                }
                out[keyword] = String(decoding: rest, as: UTF8.self)
            }
        }
        return out
    }

    /// Flux zlib de taille inconnue.
    static func inflate(_ zlib: [UInt8]) -> [UInt8]? {
        guard zlib.count > 6 else { return nil }
        let body = Array(zlib[2...])
        var capacity = max(4096, body.count * 8)
        while capacity <= 64 << 20 {
            var out = [UInt8](repeating: 0, count: capacity)
            let written = body.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    compression_decode_buffer(dst.baseAddress!, capacity, src.baseAddress!, body.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written == 0 { return nil }
            if written < capacity { return Array(out[0..<written]) }
            capacity *= 4
        }
        return nil
    }

    /// Lecteur XML minimal : éléments, attributs et texte (CDATA compris).
    final class KritaXML {
        let name: String
        let attributes: [String: String]
        var children: [KritaXML] = []
        var text = ""

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        func all(_ name: String) -> [KritaXML] {
            children.flatMap { ($0.name == name ? [$0] : []) + $0.all(name) }
        }

        static func parse(_ string: String) -> KritaXML? {
            guard let data = string.data(using: .utf8) else { return nil }
            let builder = Builder()
            let parser = XMLParser(data: data)
            parser.delegate = builder
            guard parser.parse() else { return nil }
            return builder.root
        }

        final class Builder: NSObject, XMLParserDelegate {
            var root: KritaXML?
            var stack: [KritaXML] = []

            func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
                let node = KritaXML(name: elementName, attributes: attributeDict)
                if let parent = stack.last { parent.children.append(node) } else { root = node }
                stack.append(node)
            }

            func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
                _ = stack.popLast()
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                stack.last?.text += string
            }

            func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
                stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
            }
        }
    }

    /// Préréglage Krita (.kpp) : PNG dont le texte « preset » est le XML des réglages. Le tampon est calculé (auto) ou une
    /// image nommée, cherchée dans les ressources du préréglage, puis par `resources` (fichiers d'un paquet).
    static func krita(_ kpp: [UInt8], fallbackName: String, resources: (String) -> [UInt8]?) -> BrushPreset? {
        guard let xml = pngTexts(kpp)["preset"], let preset = KritaXML.parse(xml) else { return nil }
        let name = preset.attributes["name"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        var params: [String: String] = [:]
        for param in preset.all("param") {
            if let key = param.attributes["name"] { params[key] = param.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        var ignored: [String] = []
        if let op = preset.attributes["paintopid"], op != "paintbrush" { ignored.append("moteur Krita « \(op) » (lu comme un pinceau simple)") }
        guard let definition = params["brush_definition"], let brushXML = KritaXML.parse(definition),
              let brush = brushXML.name == "Brush" ? brushXML : brushXML.all("Brush").first else { return nil }
        let spacing = brush.attributes["spacing"].flatMap(Double.init)
        let angle = brush.attributes["angle"].flatMap(Double.init) ?? 0
        var result: BrushPreset?
        if brush.attributes["type"] == "auto_brush", let mask = brush.all("MaskGenerator").first {
            let fade = mask.attributes["hfade"].flatMap(Double.init) ?? 0.5
            let ratio = mask.attributes["ratio"].flatMap(Double.init) ?? 1
            if mask.attributes["type"] != "circle" { ignored.append("tampon Krita « \(mask.attributes["type"] ?? "?") » (dessiné en rond)") }
            result = roundPreset(name: name, hardness: 1 - fade, spacing: spacing, angle: angle, roundness: min(1, max(0.05, ratio)),
                                 source: "Krita", ignored: ignored)
        } else if let file = brush.attributes["filename"] {
            // Ressources embarquées (Krita 5) : base64, avec leur nom de fichier.
            var embedded: [String: [UInt8]] = [:]
            for resource in preset.all("resource") {
                if let fileName = resource.attributes["filename"],
                   let data = Data(base64Encoded: resource.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                   options: .ignoreUnknownCharacters) {
                    embedded[(fileName as NSString).lastPathComponent.lowercased()] = [UInt8](data)
                }
            }
            let key = (file as NSString).lastPathComponent
            guard let bytes = embedded[key.lowercased()] ?? resources(key),
                  var tip = kritaTip(bytes, fileName: key) else { return nil }
            tip.name = name
            tip.spacing = spacing
            var made = self.preset(tip, source: "Krita", fallbackName: name, angle: angle)
            made.ignored = ignored
            result = made
        }
        guard var out = result else { return nil }
        if let opacity = params["OpacityValue"].flatMap(Double.init), opacity > 0, opacity <= 1 {
            out.settings.opacity = opacity
            out.mapped.append("opacité \(Int((opacity * 100).rounded())) %")
        }
        let sensors = ["PressureSize", "PressureOpacity"].filter { params[$0] == "true" }
        out.settings.pressureAffectsSize = sensors.contains("PressureSize")
        out.settings.pressureAffectsOpacity = sensors.contains("PressureOpacity")
        if !sensors.isEmpty { out.mapped.append("pression → \(sensors.map { $0 == "PressureSize" ? "taille" : "opacité" }.joined(separator: ", "))") }
        return out
    }

    /// Image d'un tampon Krita : pinceau ou pipe GIMP, ABR, ou image (PNG…) dont le gris ou l'alpha fait la forme.
    static func kritaTip(_ bytes: [UInt8], fileName: String) -> GrayTip? {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "gbr": return gimpBrush(bytes)?.tip
        case "gih": return gimpPipe(bytes).first
        case "abr":
            var r = BigEndianReader(bytes)
            guard let version = r.u16(), version <= 2 else { return nil }
            return abrOld(&r, version: version).first
        default:
            guard let image = try? ImageDecoder.decode(data: Data(bytes)) else { return nil }
            let usesAlpha = image.pixels.contains { $0.w < 0.99 }
            // Image opaque : forme noire sur fond blanc (la convention de Krita).
            let pixels = image.pixels.map { p -> UInt8 in
                let v: Float = usesAlpha ? p.w : 1 - ColorTransfer.toEncoded(max(0, 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z))
                return UInt8(min(255, max(0, v * 255)).rounded())
            }
            return GrayTip(name: "", width: image.width, height: image.height, pixels: pixels)
        }
    }

    /// Paquet Krita (.bundle) : un ZIP de préréglages (`paintoppresets/`) et des images qu'ils nomment (`brushes/`).
    static func kritaBundle(_ data: Data) -> [BrushPreset] {
        guard let zip = try? ZipArchive(data) else { return [] }
        var files: [String: ZipArchive.Entry] = [:]
        for entry in zip.entries where entry.name.lowercased().hasPrefix("brushes/") {
            files[(entry.name as NSString).lastPathComponent.lowercased()] = entry
        }
        let resources: (String) -> [UInt8]? = { name in files[name.lowercased()].flatMap { try? zip.data($0) } }
        return zip.entries.filter { $0.name.lowercased().hasPrefix("paintoppresets/") && $0.name.lowercased().hasSuffix(".kpp") }
            .compactMap { entry in
                guard let bytes = try? zip.data(entry) else { return nil }
                let base = ((entry.name as NSString).lastPathComponent as NSString).deletingPathExtension
                return krita(bytes, fallbackName: base, resources: resources)
            }
    }
}
