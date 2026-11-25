import Foundation
import PRCore
import PRStorage

/// Export Photoshop (.psd) à calques, 8 bits sRGB : un calque PSD par calque de pixels (de bas en haut), avec son nom,
/// son mode de fusion, son opacité, sa visibilité et son écrêtage ; un masque est appliqué à l'alpha du calque. Les groupes
/// ne sont pas recréés : leur opacité et leur visibilité sont reportées sur leurs calques. Les valeurs au-delà de 1 (HDR)
/// sont écrêtées. Chaque canal est compressé ligne par ligne (PackBits), par bandes : l'image entière n'est jamais en
/// mémoire non compressée.
public enum PSDWriter {
    /// Clé Photoshop du mode de fusion (Normal pour les modes qu'il n'a pas).
    static func key(_ mode: BlendMode) -> String {
        switch mode {
        case .normal: "norm"
        case .multiply: "mul "
        case .darken: "dark"
        case .colorBurn: "idiv"
        case .linearBurn: "lbrn"
        case .darkerColor: "dkCl"
        case .lighten: "lite"
        case .screen: "scrn"
        case .colorDodge: "div "
        case .add: "lddg"
        case .lighterColor: "lgCl"
        case .overlay: "over"
        case .softLight: "sLit"
        case .hardLight: "hLit"
        case .vividLight: "vLit"
        case .linearLight: "lLit"
        case .pinLight: "pLit"
        case .hardMix: "hMix"
        case .difference: "diff"
        case .exclusion: "smud"
        case .subtract: "fsub"
        case .divide: "fdiv"
        case .hue: "hue "
        case .saturation: "sat "
        case .color: "colr"
        case .luminosity: "lum "
        }
    }

    /// PackBits d'une rangée (au plus 128 octets par paquet).
    static func packBits(_ row: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        var i = row.startIndex
        let end = row.endIndex
        while i < end {
            // Répétition d'au moins 2 octets : paquet répété.
            var run = 1
            while i + run < end, run < 128, row[i + run] == row[i] { run += 1 }
            if run >= 2 {
                out.append(UInt8(bitPattern: Int8(1 - run)))
                out.append(row[i])
                i += run
                continue
            }
            // Littéraux jusqu'à la prochaine répétition.
            var count = 1
            while i + count < end, count < 128 {
                if i + count + 1 < end, row[i + count] == row[i + count + 1] { break }
                count += 1
            }
            out.append(UInt8(count - 1))
            out.append(contentsOf: row[i..<(i + count)])
            i += count
        }
        return out
    }

    /// Canaux compressés d'une image (rangées PackBits par canal) : R, G, B, puis A si `alpha`.
    struct Planes {
        var rows: [[[UInt8]]]

        /// Octets d'un canal tel qu'il est écrit dans un calque : compression (1), longueurs des rangées, données.
        func layerChannel(_ c: Int) -> [UInt8] {
            var out: [UInt8] = [0, 1]
            for row in rows[c] { out += be16(UInt16(row.count)) }
            for row in rows[c] { out += row }
            return out
        }
    }

    /// Assemble des morceaux d'octets (plus rapide à typer qu'une chaîne de « + »).
    static func cat(_ parts: [UInt8]...) -> [UInt8] { parts.flatMap { $0 } }

    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    /// Lit une source par bandes et compresse ses canaux (valeurs linéaires prémultipliées → sRGB 8 bits non prémultiplié).
    static func planes(_ source: LayerRowSource, alpha: Bool, progress: (Double) -> Bool) throws -> Planes {
        let width = source.width, height = source.height
        let channels = alpha ? 4 : 3
        var rows = [[[UInt8]]](repeating: [], count: channels)
        for c in 0..<channels { rows[c].reserveCapacity(height) }
        var y = 0
        while y < height {
            let count = min(256, height - y)
            let pixels = source.rows(y, count)
            for r in 0..<count {
                var planes = [[UInt8]](repeating: [UInt8](repeating: 0, count: width), count: channels)
                for x in 0..<width {
                    let p = pixels[r * width + x]
                    let a = min(1, max(0, p.w))
                    let rgb = a > 1e-6 ? SIMD3(p.x, p.y, p.z) / a : .zero
                    planes[0][x] = ColorTransfer.encode8(rgb.x)
                    planes[1][x] = ColorTransfer.encode8(rgb.y)
                    planes[2][x] = ColorTransfer.encode8(rgb.z)
                    if alpha { planes[3][x] = UInt8((a * 255).rounded()) }
                }
                for c in 0..<channels { rows[c].append(packBits(planes[c][...])) }
            }
            y += count
            guard progress(Double(y) / Double(height)) else { throw ExportError.cancelled }
        }
        return Planes(rows: rows)
    }

    /// Nom Pascal (MacRoman approché par l'ASCII), longueur comprise, complété à un multiple de 4.
    static func pascalName(_ name: String) -> [UInt8] {
        let ascii = Array(name.unicodeScalars.map { $0.isASCII ? UInt8($0.value) : UInt8(ascii: "_") }.prefix(255))
        var out = [UInt8(ascii.count)] + ascii
        while out.count % 4 != 0 { out.append(0) }
        return out
    }

    /// Bloc « luni » : le nom en Unicode.
    static func unicodeName(_ name: String) -> [UInt8] {
        var data = be32(UInt32(name.utf16.count))
        for unit in name.utf16 { data += be16(unit) }
        while data.count % 4 != 0 { data.append(0) }
        return cat(Array("8BIM".utf8), Array("luni".utf8), be32(UInt32(data.count)), data)
    }

    /// Exporte la pile. `paper` : fond de l'image composée (nil = transparent). Renvoie l'URL écrite.
    @discardableResult
    public static func export(_ stack: LayerStack, downscale: Int = 1, paper: SIMD3<Float>?, space: BlendSpace = .perceptual,
                              to url: URL, progress: @escaping ExportProgress = { _ in true }) throws -> URL {
        let width = stack.width / downscale, height = stack.height / downscale
        guard width <= 30_000, height <= 30_000 else { throw ExportError.tooLarge }
        let byID = Dictionary(uniqueKeysWithValues: stack.items.map { ($0.id, $0) })
        // Visibilité et opacité des groupes, reportées sur leurs calques.
        func inherited(_ item: StackItem) -> (visible: Bool, opacity: Float) {
            var visible = item.isVisible, opacity = item.opacity
            var parent = item.parent
            while let id = parent, let group = byID[id] {
                visible = visible && group.isVisible
                opacity *= group.opacity
                parent = group.parent
            }
            return (visible, opacity)
        }
        let layers = stack.items.filter { $0.layer != nil }
        let steps = Double(layers.count + 1)

        var records: [UInt8] = []
        var channelData: [UInt8] = []
        for (index, item) in layers.enumerated() {
            // Le calque seul, masque appliqué, en Normal et opaque : mode et opacité vont dans l'en-tête du calque.
            var alone = item
            alone.parent = nil
            alone.opacity = 1
            alone.isVisible = true
            alone.blendMode = .normal
            alone.isClipped = false
            let single = LayerStack(width: stack.width, height: stack.height, format: stack.format, items: [alone])
            let source = LayerRowSource(stack: single, downscale: downscale, paper: nil, space: space)
            let encoded = try planes(source, alpha: true) { progress((Double(index) + $0) / steps) }
            let channels = [3, 0, 1, 2].map { encoded.layerChannel($0) }
            let state = inherited(item)
            records += cat(be32(0), be32(0), be32(UInt32(height)), be32(UInt32(width)))
            records += be16(4)
            for (id, data) in zip([Int16(-1), 0, 1, 2], channels) {
                records += be16(UInt16(bitPattern: id)) + be32(UInt32(data.count))
            }
            records += Array("8BIM".utf8) + Array(key(item.blendMode).utf8)
            records += [UInt8((min(1, max(0, state.opacity)) * 255).rounded()), item.isClipped ? 1 : 0,
                        state.visible ? 0 : 2, 0]
            let extra = cat(be32(0), be32(0), pascalName(item.name), unicodeName(item.name))
            records += be32(UInt32(extra.count)) + extra
            for data in channels { channelData += data }
        }

        // Image composée : canaux plans, longueurs de toutes les rangées d'abord.
        let composite = try planes(LayerRowSource(stack: stack, downscale: downscale, paper: paper, space: space),
                                   alpha: paper == nil) { progress((Double(layers.count) + $0) / steps) }
        let compositeChannels = composite.rows.count

        var layerInfo = be16(UInt16(bitPattern: Int16(paper == nil ? -layers.count : layers.count))) + records + channelData
        if layerInfo.count % 2 != 0 { layerInfo.append(0) }
        let layerSection = be32(UInt32(layerInfo.count)) + layerInfo + be32(0)

        var out = Data()
        out.append(contentsOf: Array("8BPS".utf8) + be16(1) + [UInt8](repeating: 0, count: 6))
        out.append(contentsOf: cat(be16(UInt16(compositeChannels)), be32(UInt32(height)), be32(UInt32(width)), be16(8), be16(3)))
        out.append(contentsOf: be32(0) + be32(0))
        out.append(contentsOf: be32(UInt32(layerSection.count)) + layerSection)
        out.append(contentsOf: be16(1))
        for c in 0..<compositeChannels { for row in composite.rows[c] { out.append(contentsOf: be16(UInt16(row.count))) } }
        for c in 0..<compositeChannels { for row in composite.rows[c] { out.append(contentsOf: row) } }

        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).writing")
        try out.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: temporary, to: url)
        return url
    }
}
