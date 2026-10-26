import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import PRCore
import simd
import UniformTypeIdentifiers

/// Timelapse par captures : une image JPEG réduite de la vue dépliée après chaque opération, numérotée dans un dossier.
/// Les écritures passent par une file série (l'encodage JPEG ne bloque pas l'interface).
public final class TimelapseRecorder: @unchecked Sendable {
    public let directory: URL
    private let queue = DispatchQueue(label: "prorange.timelapse")
    private var count: Int

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        count = Self.frames(in: directory).count
    }

    /// Nombre d'images enregistrées (écritures en cours comprises).
    public var frameCount: Int { queue.sync { count } }

    public static func frames(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".jpg") }.sorted().map { directory.appendingPathComponent($0) }
    }

    public var frameURLs: [URL] {
        queue.sync {}
        return Self.frames(in: directory)
    }

    /// Ajoute une image RGBA 8 bits sRGB (lignes de haut en bas, alpha ignoré).
    public func append(rgba: [UInt8], width: Int, height: Int) {
        queue.async { [self] in
            count += 1
            let url = directory.appendingPathComponent(String(format: "%06d.jpg", count))
            Self.writeJPEG(rgba, width: width, height: height, to: url)
        }
    }

    /// Efface toutes les images (nouveau projet).
    public func reset() {
        queue.sync {
            for url in Self.frames(in: directory) { try? FileManager.default.removeItem(at: url) }
            count = 0
        }
    }

    /// Remplace les images par celles d'un autre dossier (ouverture d'un projet).
    public func replace(with source: URL) {
        queue.sync {
            for url in Self.frames(in: directory) { try? FileManager.default.removeItem(at: url) }
            let incoming = Self.frames(in: source)
            for url in incoming { try? FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(url.lastPathComponent)) }
            count = incoming.count
        }
    }

    /// Copie les images dans `destination` (enregistrement du projet), en remplaçant son contenu.
    public func copy(to destination: URL) throws {
        try queue.sync {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: directory, to: destination)
        }
    }

    static func writeJPEG(_ rgba: [UInt8], width: Int, height: Int, to url: URL) {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}

/// Vue de la vidéo : le panorama déplié tel quel, ou une vue sphère qui fait le tour pendant la vidéo.
public enum TimelapseView: Sendable, Equatable {
    case unfolded
    case sphere(fovDegrees: Double, turns: Double)
}

/// Assemble les captures en vidéo H.265 (HEVC) avec AVAssetWriter.
public enum TimelapseExporter {
    public enum Failure: Error {
        case noFrames
        case writerFailed(String)
    }

    /// `minimumDuration` : les images sont répétées pour que la vidéo dure au moins ce temps ; la dernière est tenue 1 s.
    public static func export(frames: [URL], to url: URL, width: Int, height: Int, framesPerSecond: Int = 30,
                              view: TimelapseView = .unfolded, minimumDuration: Double = 3,
                              progress: ExportProgress = { _ in true }) throws {
        guard !frames.isEmpty else { throw Failure.noFrames }
        let width = width & ~1
        let height = height & ~1
        guard width > 0, height > 0 else { throw ExportError.invalidDimensions }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw Failure.writerFailed("entrée vidéo refusée") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writerFailed(writer.error.map { "\($0)" } ?? "démarrage") }
        writer.startSession(atSourceTime: .zero)

        let repeats = max(1, Int((minimumDuration * Double(framesPerSecond) / Double(frames.count)).rounded(.up)))
        var time: Int64 = 0
        var completed = false
        defer {
            if !completed {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
            }
        }
        for (index, frame) in frames.enumerated() {
            guard let source = CGImageSourceCreateWithURL(frame as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let hold = index == frames.count - 1 ? max(repeats, framesPerSecond) : repeats
            let t = Double(index) / Double(max(1, frames.count - 1))
            guard let buffer = try makeBuffer(image, view: view, progress: t, width: width, height: height, pool: adaptor.pixelBufferPool) else {
                continue
            }
            for _ in 0..<hold {
                while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: time, timescale: CMTimeScale(framesPerSecond))) else {
                    throw Failure.writerFailed(writer.error.map { "\($0)" } ?? "ajout d'image")
                }
                time += 1
            }
            guard progress(Double(index + 1) / Double(frames.count)) else { throw ExportError.cancelled }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw Failure.writerFailed(writer.error.map { "\($0)" } ?? "finalisation") }
        completed = true
    }

    private static func makeBuffer(_ image: CGImage, view: TimelapseView, progress t: Double, width: Int, height: Int,
                                   pool: CVPixelBufferPool?) throws -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
        } else {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &created)
        }
        guard let buffer = created else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        switch view {
        case .unfolded:
            guard let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes,
                                          space: space, bitmapInfo: info) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        case let .sphere(fov, turns):
            let panorama = rgba(of: image)
            var state = ViewState()
            state.mode = .sphere
            state.fov = fov * .pi / 180
            state.yaw = t * turns * 2 * .pi
            let parameters = state.parameters(aspect: Double(width) / Double(height))
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let ndc = SIMD2<Double>((Double(x) + 0.5) / Double(width) * 2 - 1, 1 - (Double(y) + 0.5) / Double(height) * 2)
                    let d = parameters.rectilinearDirection(ndc: ndc)
                    let p = Equirect.pixel(from: d, width: panorama.width, height: panorama.height)
                    let c = panorama.sample(p.x, p.y)
                    let o = y * rowBytes + x * 4
                    pixels[o] = c.z
                    pixels[o + 1] = c.y
                    pixels[o + 2] = c.x
                    pixels[o + 3] = 255
                }
            }
        }
        return buffer
    }

    /// Image 8 bits en mémoire avec échantillonnage bilinéaire bouclé en x.
    private struct Panorama {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func sample(_ px: Double, _ py: Double) -> SIMD3<UInt8> {
            let x = px - 0.5
            let y = min(Double(height - 1), max(0, py - 0.5))
            let x0 = Int(floor(x))
            let y0 = Int(floor(y))
            let fx = x - Double(x0)
            let fy = y - Double(y0)
            let xa = ((x0 % width) + width) % width
            let xb = (xa + 1) % width
            let yb = min(height - 1, y0 + 1)
            func at(_ x: Int, _ y: Int) -> SIMD3<Double> {
                let o = (y * width + x) * 4
                return SIMD3(Double(bytes[o]), Double(bytes[o + 1]), Double(bytes[o + 2]))
            }
            let top = at(xa, y0) * (1 - fx) + at(xb, y0) * fx
            let bottom = at(xa, yb) * (1 - fx) + at(xb, yb) * fx
            let c = top * (1 - fy) + bottom * fy
            return SIMD3(UInt8(min(255, c.x + 0.5)), UInt8(min(255, c.y + 0.5)), UInt8(min(255, c.z + 0.5)))
        }
    }

    private static func rgba(of image: CGImage) -> Panorama {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        if let space = CGColorSpace(name: CGColorSpace.sRGB) {
            bytes.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return Panorama(width: width, height: height, bytes: bytes)
    }
}
