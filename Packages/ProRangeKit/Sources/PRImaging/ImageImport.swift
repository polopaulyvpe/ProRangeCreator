import CoreGraphics
import Foundation
import ImageIO
import PRCore
import PRStorage
import simd

/// Image importée, en RGBA linéaire prémultiplié, lignes de haut en bas. Décodée entièrement en mémoire
/// (16 octets par pixel : 512 Mo pour une 8K).
public struct ImportedImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [SIMD4<Float>]

    public init(width: Int, height: Int, pixels: [SIMD4<Float>]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    @inline(__always)
    func pixel(_ x: Int, _ y: Int) -> SIMD4<Float> { pixels[y * width + x] }

    /// Bilinéaire en coordonnées pixel continues (centre du texel en +0,5), bouclé en x si `wrap`, borné sinon.
    func sample(_ px: Double, _ py: Double, wrap: Bool) -> SIMD4<Float> {
        let x = px - 0.5
        let y = min(Double(height - 1), max(0, py - 0.5))
        var x0 = Int(floor(x))
        let fx = Float(x - Double(x0))
        let y0 = Int(floor(y))
        let fy = Float(y - Double(y0))
        var x1 = x0 + 1
        if wrap {
            x0 = ((x0 % width) + width) % width
            x1 = (x0 + 1) % width
        } else {
            x0 = min(width - 1, max(0, x0))
            x1 = min(width - 1, max(0, x1))
        }
        let y1 = min(height - 1, y0 + 1)
        let top = pixel(x0, y0) * (1 - fx) + pixel(x1, y0) * fx
        let bottom = pixel(x0, y1) * (1 - fx) + pixel(x1, y1) * fx
        return top * (1 - fy) + bottom * fy
    }
}

/// Décodage : ImageIO pour tout ce qu'il connaît (PNG, JPG, HEIC, TIFF, PSD aplati, EXR toutes compressions, souvent HDR),
/// avec gestion de couleur vers le sRGB linéaire étendu ; lecteurs maison EXR et Radiance en repli.
public enum ImageDecoder {
    public enum Failure: Error, Equatable {
        case unreadable
        case tooLarge(width: Int, height: Int)
    }

    /// Plafond de pixels décodés (16K × 8K).
    public static let maxPixels = 16384 * 8192

    public static func decode(_ url: URL) throws -> ImportedImage {
        let ext = url.pathExtension.lowercased()
        if ext == "hdr" || ext == "pic", let image = try? RadianceReader.read(url) {
            return ImportedImage(width: image.width, height: image.height, pixels: image.pixels.map { SIMD4<Float>($0.x, $0.y, $0.z, 1) })
        }
        if ext == "exr" {
            // Notre lecteur (aucune compression, ZIP, ZIPS) garde l'alpha prémultiplié d'OpenEXR ; ImageIO pour le reste.
            if let image = try? EXRReader.read(url) {
                return ImportedImage(width: image.width, height: image.height, pixels: image.pixels)
            }
            if let image = try decodeEXRWithImageIO(url) { return image }
            throw Failure.unreadable
        }
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = try decode(source) {
            return image
        }
        throw Failure.unreadable
    }

    /// ImageIO lit l'EXR comme un alpha droit et le prémultiplie une seconde fois : on divise une fois par alpha.
    static func decodeEXRWithImageIO(_ url: URL) throws -> ImportedImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), var image = try decode(source) else { return nil }
        for i in image.pixels.indices {
            let a = image.pixels[i].w
            if a > 0 && a < 1 {
                let p = image.pixels[i]
                image.pixels[i] = SIMD4<Float>(p.x / a, p.y / a, p.z / a, a)
            }
        }
        return image
    }

    /// Données en mémoire (presse-papiers, Photos).
    public static func decode(data: Data) throws -> ImportedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = try decode(source) else {
            throw Failure.unreadable
        }
        return image
    }

    private static func decode(_ source: CGImageSource) throws -> ImportedImage? {
        guard CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary)
        else { return nil }
        return try decode(image)
    }

    /// Dessine l'image dans un contexte flottant sRGB linéaire étendu, prémultiplié : les valeurs HDR passent telles quelles.
    public static func decode(_ image: CGImage) throws -> ImportedImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw Failure.unreadable }
        guard width * height <= maxPixels else { throw Failure.tooLarge(width: width, height: height) }
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { throw Failure.unreadable }
        var pixels = [SIMD4<Float>](repeating: .zero, count: width * height)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 32,
                                          bytesPerRow: width * 16, space: space, bitmapInfo: info) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw Failure.unreadable }
        return ImportedImage(width: width, height: height, pixels: pixels)
    }
}

/// Mise au format 2:1 d'une image qui ne l'est pas.
public enum PanoramaFit: String, CaseIterable, Sendable {
    /// Recadrage au centre.
    case crop
    /// Marges transparentes.
    case pad
    /// Étirement.
    case stretch

    public var label: String {
        switch self {
        case .crop: "Recadrer"
        case .pad: "Marges transparentes"
        case .stretch: "Étirer"
        }
    }
}

/// Disposition d'un cubemap reçu en une seule image.
public enum CubemapSourceLayout: String, Sendable {
    case horizontalCross
    case verticalCross
    case horizontalStrip
    case verticalStrip

    /// Déduite des proportions de l'image (4:3, 3:4, 6:1, 1:6).
    public static func detect(width: Int, height: Int) -> CubemapSourceLayout? {
        if width * 3 == height * 4 { return .horizontalCross }
        if width * 4 == height * 3 { return .verticalCross }
        if width == height * 6 { return .horizontalStrip }
        if height == width * 6 { return .verticalStrip }
        return nil
    }

    public var label: String {
        switch self {
        case .horizontalCross: "croix horizontale"
        case .verticalCross: "croix verticale"
        case .horizontalStrip: "bande 6 × 1"
        case .verticalStrip: "bande 1 × 6"
        }
    }
}

/// Écriture d'images importées dans un calque (modes A et C de l'import ; le mode B passe par `TiledLayer.placeImage`).
/// À appeler entre `beginOperation` et `endOperation` du calque : l'import est une opération annulable.
public enum PanoramaImport {
    /// Rectangles source (pixels de l'image) et cible (pixels du calque) selon l'ajustement.
    static func rectangles(imageWidth: Int, imageHeight: Int, width: Int, height: Int, fit: PanoramaFit)
        -> (source: CGRect, target: CGRect) {
        let full = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let aspect = Double(imageWidth) / Double(imageHeight)
        let wanted = Double(width) / Double(height)
        guard abs(aspect - wanted) > 1e-6, fit != .stretch else { return (full, canvas) }
        switch fit {
        case .crop:
            if aspect > wanted {
                let w = Double(imageHeight) * wanted
                return (CGRect(x: (Double(imageWidth) - w) / 2, y: 0, width: w, height: Double(imageHeight)), canvas)
            }
            let h = Double(imageWidth) / wanted
            return (CGRect(x: 0, y: (Double(imageHeight) - h) / 2, width: Double(imageWidth), height: h), canvas)
        case .pad:
            if aspect > wanted {
                let h = Double(width) / aspect
                return (full, CGRect(x: 0, y: (Double(height) - h) / 2, width: Double(width), height: h))
            }
            let w = Double(height) * aspect
            return (full, CGRect(x: (Double(width) - w) / 2, y: 0, width: w, height: Double(height)))
        case .stretch:
            return (full, canvas)
        }
    }

    /// Mode A : panorama équirectangulaire, rééchantillonné à la taille du calque (moyenne de plusieurs points
    /// quand on réduit), tourné de `yawDegrees` autour de la verticale. Renvoie les tuiles écrites.
    @discardableResult
    public static func equirectangular(_ image: ImportedImage, into layer: TiledLayer, fit: PanoramaFit,
                                       yawDegrees: Double = 0) -> Set<TileCoord> {
        let (source, target) = rectangles(imageWidth: image.width, imageHeight: image.height,
                                          width: layer.width, height: layer.height, fit: fit)
        let scaleX = source.width / target.width
        let scaleY = source.height / target.height
        let nx = max(1, min(8, Int(scaleX.rounded(.up))))
        let ny = max(1, min(8, Int(scaleY.rounded(.up))))
        // Bouclage en x seulement si l'image couvre tout le tour.
        let wrap = target.width >= Double(layer.width) - 0.5 && source.width >= Double(image.width) - 0.5
        let layerWidth = Double(layer.width)
        let shift = yawDegrees / 360 * layerWidth
        let weight = 1 / Float(nx * ny)
        return fill(layer) { x, y in
            var tx = Double(x) + 0.5 - shift
            if wrap { tx -= floor(tx / layerWidth) * layerWidth }
            let ty = Double(y) + 0.5
            guard tx >= target.minX, tx < target.maxX, ty >= target.minY, ty < target.maxY else { return .zero }
            var sum = SIMD4<Float>.zero
            for j in 0..<ny {
                let oy = ty - 0.5 + (Double(j) + 0.5) / Double(ny)
                let sy = source.minY + (oy - target.minY) * scaleY
                for i in 0..<nx {
                    let ox = tx - 0.5 + (Double(i) + 0.5) / Double(nx)
                    let sx = source.minX + (ox - target.minX) * scaleX
                    sum += image.sample(sx, sy, wrap: wrap)
                }
            }
            return sum * weight
        }
    }

    /// Mode C : six faces carrées (ordre +X −X +Y −Y +Z −Z, convention OpenGL, comme l'export) vers l'équirectangulaire.
    @discardableResult
    public static func cubemap(_ faces: [ImportedImage], into layer: TiledLayer) -> Set<TileCoord> {
        precondition(faces.count == 6, "six faces attendues")
        let size = faces[0].width
        // Suréchantillonnage quand les faces sont plus fines que le calque.
        let layerWidth = Double(layer.width)
        let layerHeight = Double(layer.height)
        let n = max(1, min(4, Int((Double(size) * 4 / layerWidth).rounded(.up))))
        let weight = 1 / Float(n * n)
        return fill(layer) { x, y in
            var sum = SIMD4<Float>.zero
            for j in 0..<n {
                for i in 0..<n {
                    let u = (Double(x) + (Double(i) + 0.5) / Double(n)) / layerWidth
                    let v = (Double(y) + (Double(j) + 0.5) / Double(n)) / layerHeight
                    let (face, a, b) = CubemapFace.locate(Equirect.direction(u: u, v: v))
                    let image = faces[face.rawValue]
                    sum += image.sample((a + 1) / 2 * Double(image.width), (b + 1) / 2 * Double(image.height), wrap: false)
                }
            }
            return sum * weight
        }
    }

    /// Découpe une croix ou une bande en six faces (ordre +X −X +Y −Y +Z −Z).
    public static func faces(from image: ImportedImage, layout: CubemapSourceLayout) -> [ImportedImage] {
        let size: Int
        var cells: [CubemapFace: (Int, Int)] = [:]
        var rotated: CubemapFace?
        switch layout {
        case .horizontalCross:
            size = image.width / 4
            for face in CubemapFace.allCases { cells[face] = face.crossCell }
        case .verticalCross:
            size = image.width / 3
            cells = [.py: (1, 0), .nx: (0, 1), .pz: (1, 1), .px: (2, 1), .ny: (1, 2), .nz: (1, 3)]
            rotated = .nz // −Z est retournée de 180° en bas de la croix verticale
        case .horizontalStrip:
            size = image.height
            for face in CubemapFace.allCases { cells[face] = (face.rawValue, 0) }
        case .verticalStrip:
            size = image.width
            for face in CubemapFace.allCases { cells[face] = (0, face.rawValue) }
        }
        return CubemapFace.allCases.map { face in
            let (column, row) = cells[face]!
            var pixels = [SIMD4<Float>](repeating: .zero, count: size * size)
            for y in 0..<size {
                for x in 0..<size {
                    let (sx, sy) = face == rotated ? (size - 1 - x, size - 1 - y) : (x, y)
                    pixels[y * size + x] = image.pixel(column * size + sx, row * size + sy)
                }
            }
            return ImportedImage(width: size, height: size, pixels: pixels)
        }
    }

    /// Remplit le calque tuile par tuile (en parallèle) ; les tuiles entièrement transparentes ne sont pas créées.
    private static func fill(_ layer: TiledLayer, _ value: @escaping @Sendable (Int, Int) -> SIMD4<Float>) -> Set<TileCoord> {
        let side = TileSize.side
        let coords = (0..<layer.tilesDown).flatMap { ty in (0..<layer.tilesAcross).map { TileCoord(x: $0, y: ty) } }
        let width = layer.width
        let height = layer.height
        var results = [[SIMD4<Float>]?](repeating: nil, count: coords.count)
        results.withUnsafeMutableBufferPointer { out in
            let buffer = UncheckedBuffer(out)
            DispatchQueue.concurrentPerform(iterations: coords.count) { i in
                let coord = coords[i]
                var pixels = [SIMD4<Float>](repeating: .zero, count: side * side)
                var any = false
                for y in 0..<side {
                    let gy = coord.y * side + y
                    guard gy < height else { break }
                    for x in 0..<side {
                        let gx = coord.x * side + x
                        guard gx < width else { break }
                        let p = value(gx, gy)
                        if p != .zero { any = true }
                        pixels[y * side + x] = p
                    }
                }
                buffer.base[i] = any ? pixels : nil
            }
        }
        var written = Set<TileCoord>()
        for (i, coord) in coords.enumerated() {
            if let pixels = results[i] {
                layer.replaceTile(coord, withPixels: pixels)
                written.insert(coord)
            } else if layer.isStored(coord) {
                layer.replaceTile(coord, withPixels: [SIMD4<Float>](repeating: .zero, count: side * side))
                written.insert(coord)
            }
        }
        return written
    }
}

/// Tampon partagé entre les itérations de `concurrentPerform`, chacune n'écrivant que son propre indice.
private struct UncheckedBuffer<Element>: @unchecked Sendable {
    let base: UnsafeMutableBufferPointer<Element>
    init(_ base: UnsafeMutableBufferPointer<Element>) { self.base = base }
}
