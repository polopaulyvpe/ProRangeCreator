import Compression
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Flux zlib continu (en-tête, DEFLATE du framework Compression, Adler-32) : un PNG n'a qu'un flux pour tout son IDAT.
final class ZlibStream {
    enum Failure: Error {
        case initFailed
        case processFailed
    }

    private let stream: UnsafeMutablePointer<compression_stream>
    private let buffer: UnsafeMutablePointer<UInt8>
    private let bufferSize = 1 << 16
    private var a: UInt32 = 1
    private var b: UInt32 = 0
    private var started = false

    init() throws {
        stream = .allocate(capacity: 1)
        buffer = .allocate(capacity: bufferSize)
        guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            stream.deallocate()
            buffer.deallocate()
            throw Failure.initFailed
        }
    }

    deinit {
        compression_stream_destroy(stream)
        stream.deallocate()
        buffer.deallocate()
    }

    /// Compresse `input` ; avec `final`, termine le flux (et ajoute la somme Adler-32).
    func process(_ input: [UInt8], final: Bool) throws -> [UInt8] {
        var out: [UInt8] = started ? [] : [0x78, 0x9C]
        started = true
        updateChecksum(input)
        var source = input.isEmpty ? [UInt8(0)] : input
        let sourceCount = input.count
        try source.withUnsafeMutableBufferPointer { src in
            stream.pointee.src_ptr = UnsafePointer(src.baseAddress!)
            stream.pointee.src_size = sourceCount
            let flags = final ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = bufferSize
                let status = compression_stream_process(stream, flags)
                guard status != COMPRESSION_STATUS_ERROR else { throw Failure.processFailed }
                out.append(contentsOf: UnsafeBufferPointer(start: buffer, count: bufferSize - stream.pointee.dst_size))
                if status == COMPRESSION_STATUS_END { break }
                if !final && stream.pointee.src_size == 0 && stream.pointee.dst_size > 0 { break }
            }
        }
        if final {
            let checksum = (b << 16) | a
            out.append(contentsOf: [UInt8(checksum >> 24), UInt8((checksum >> 16) & 0xFF), UInt8((checksum >> 8) & 0xFF), UInt8(checksum & 0xFF)])
        }
        return out
    }

    private func updateChecksum(_ data: [UInt8]) {
        var index = 0
        while index < data.count {
            let end = min(index + 5552, data.count)
            while index < end {
                a += UInt32(data[index])
                b += a
                index += 1
            }
            a %= 65521
            b %= 65521
        }
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ parts: [UInt8]...) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for part in parts {
            for byte in part { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }
}

/// Fichier écrit d'un bout à l'autre, supprimé si l'écriture n'aboutit pas.
final class OutputFile {
    let handle: FileHandle
    private let url: URL
    private(set) var position: UInt64 = 0
    var completed = false

    init(_ url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? handle.close()
        if !completed { try? FileManager.default.removeItem(at: url) }
    }

    func write(_ bytes: [UInt8]) throws {
        try handle.write(contentsOf: Data(bytes))
        position += UInt64(bytes.count)
    }
}

/// Écrivain PNG en flux (8 ou 16 bits, RGB ou RGBA, filtre « Up »). Les lignes reçues sont des couleurs encodées
/// dans [0, 1], non prémultipliées (voir `DisplayTransform`).
public enum PNGWriter {
    public static func write(to url: URL, width: Int, height: Int, bitDepth: Int, includeAlpha: Bool, bandHeight: Int = 256,
                             rows: RowProvider, progress: ExportProgress = { _ in true }) throws {
        guard width > 0, height > 0, bitDepth == 8 || bitDepth == 16 else { throw ExportError.invalidDimensions }
        let file = try OutputFile(url)
        try file.write([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr: [UInt8] = []
        appendBE(&ihdr, UInt32(width))
        appendBE(&ihdr, UInt32(height))
        ihdr += [UInt8(bitDepth), includeAlpha ? 6 : 2, 0, 0, 0]
        try chunk(file, "IHDR", ihdr)
        try chunk(file, "sRGB", [0])

        let channels = includeAlpha ? 4 : 3
        let bytesPerSample = bitDepth / 8
        let rowBytes = width * channels * bytesPerSample
        let zlib = try ZlibStream()
        var previous = [UInt8](repeating: 0, count: rowBytes)
        var y = 0
        while y < height {
            let count = min(bandHeight, height - y)
            let band = try rows(y, count)
            var filtered: [UInt8] = []
            filtered.reserveCapacity(count * (rowBytes + 1))
            var line = [UInt8](repeating: 0, count: rowBytes)
            for row in 0..<count {
                var i = 0
                for x in 0..<width {
                    let p = band[row * width + x]
                    for k in 0..<channels {
                        let v = min(1, max(0, p[k]))
                        if bitDepth == 8 {
                            line[i] = UInt8(v * 255 + 0.5)
                            i += 1
                        } else {
                            let s = UInt16(v * 65535 + 0.5)
                            line[i] = UInt8(s >> 8)
                            line[i + 1] = UInt8(s & 0xFF)
                            i += 2
                        }
                    }
                }
                filtered.append(2) // filtre Up : différence avec la ligne du dessus
                for j in 0..<rowBytes { filtered.append(line[j] &- previous[j]) }
                swap(&previous, &line)
            }
            y += count
            let compressed = try zlib.process(filtered, final: y >= height)
            if !compressed.isEmpty { try chunk(file, "IDAT", compressed) }
            guard progress(Double(y) / Double(height)) else { throw ExportError.cancelled }
        }
        try chunk(file, "IEND", [])
        file.completed = true
    }

    private static func appendBE(_ bytes: inout [UInt8], _ v: UInt32) {
        bytes += [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private static func chunk(_ file: OutputFile, _ type: String, _ data: [UInt8]) throws {
        var bytes: [UInt8] = []
        appendBE(&bytes, UInt32(data.count))
        let typeBytes = Array(type.utf8)
        bytes += typeBytes
        bytes += data
        appendBE(&bytes, CRC32.checksum(typeBytes, data))
        try file.write(bytes)
    }
}

/// Écrivain TIFF en flux : flottants 16 (half) ou 32 bits, linéaires, alpha associé (prémultiplié, comme le calque),
/// bandes de 16 lignes compressées en Deflate. TIFF classique : refusé au-delà de 4 Gio (utiliser EXR).
public enum TIFFWriter {
    public static func write(to url: URL, width: Int, height: Int, bitsPerSample: Int, includeAlpha: Bool, bandHeight: Int = 256,
                             rows: RowProvider, progress: ExportProgress = { _ in true }) throws {
        guard width > 0, height > 0, bitsPerSample == 16 || bitsPerSample == 32, bandHeight % 16 == 0 else {
            throw ExportError.invalidDimensions
        }
        let rowsPerStrip = 16
        let channels = includeAlpha ? 4 : 3
        let file = try OutputFile(url)
        var header = ByteWriter()
        header.append([0x49, 0x49])
        header.append(UInt16(42))
        header.append(UInt32(0)) // offset de l'IFD, écrit à la fin
        try file.write(header.bytes)

        var offsets: [UInt64] = []
        var counts: [UInt64] = []
        var y = 0
        while y < height {
            let count = min(bandHeight, height - y)
            let band = try rows(y, count)
            var line = 0
            while line < count {
                let lines = min(rowsPerStrip, count - line)
                var raw = ByteWriter()
                raw.bytes.reserveCapacity(lines * width * channels * bitsPerSample / 8)
                for i in (line * width)..<((line + lines) * width) {
                    let p = band[i]
                    for k in 0..<channels {
                        if bitsPerSample == 16 { raw.append(Float16(p[k])) } else { raw.append(p[k]) }
                    }
                }
                let strip = Zlib.compress(raw.bytes, always: true) ?? raw.bytes
                offsets.append(file.position)
                counts.append(UInt64(strip.count))
                try file.write(strip)
                line += lines
            }
            y += count
            guard progress(Double(y) / Double(height)) else { throw ExportError.cancelled }
        }
        if file.position % 2 == 1 { try file.write([0]) }

        // Valeurs trop longues pour tenir dans une entrée : écrites avant l'IFD.
        var extra = ByteWriter()
        let extraStart = file.position
        func place(_ build: (inout ByteWriter) -> Void) -> UInt64 {
            let at = extraStart + UInt64(extra.bytes.count)
            build(&extra)
            if extra.bytes.count % 2 == 1 { extra.append(UInt8(0)) }
            return at
        }
        let bitsAt = place { w in for _ in 0..<channels { w.append(UInt16(bitsPerSample)) } }
        let formatAt = place { w in for _ in 0..<channels { w.append(UInt16(3)) } }
        let offsetsAt = place { w in for o in offsets { w.append(UInt32(truncatingIfNeeded: o)) } }
        let countsAt = place { w in for c in counts { w.append(UInt32(truncatingIfNeeded: c)) } }
        let ifdAt = extraStart + UInt64(extra.bytes.count)
        guard ifdAt + 1024 < UInt64(UInt32.max) else { throw ExportError.tooLarge }
        try file.write(extra.bytes)

        // (tag, type, nombre, valeur ou offset) ; SHORT = 3, LONG = 4, triés par tag.
        var entries: [(UInt16, UInt16, UInt32, UInt32)] = [
            (256, 4, 1, UInt32(width)),
            (257, 4, 1, UInt32(height)),
            (258, 3, UInt32(channels), UInt32(bitsAt)),
            (259, 3, 1, 8),                                  // Deflate (zlib)
            (262, 3, 1, 2),                                  // RVB
            (273, 4, UInt32(offsets.count), offsets.count == 1 ? UInt32(offsets[0]) : UInt32(offsetsAt)),
            (277, 3, 1, UInt32(channels)),
            (278, 4, 1, UInt32(rowsPerStrip)),
            (279, 4, UInt32(counts.count), counts.count == 1 ? UInt32(counts[0]) : UInt32(countsAt)),
            (284, 3, 1, 1),                                  // pixels entrelacés
        ]
        if includeAlpha { entries.append((338, 3, 1, 1)) }  // alpha associé (prémultiplié)
        entries.append((339, 3, UInt32(channels), UInt32(formatAt))) // flottants
        var ifd = ByteWriter()
        ifd.append(UInt16(entries.count))
        for (tag, type, count, value) in entries {
            ifd.append(tag)
            ifd.append(type)
            ifd.append(count)
            ifd.append(value)
        }
        ifd.append(UInt32(0))
        try file.write(ifd.bytes)
        try file.handle.seek(toOffset: 4)
        try file.handle.write(contentsOf: Data(withUnsafeBytes(of: UInt32(ifdAt).littleEndian) { Array($0) }))
        file.completed = true
    }
}

/// JPEG par ImageIO (pas d'encodeur maison). Les lignes sont fournies à la demande par un fournisseur séquentiel,
/// mais ImageIO peut garder l'image entière en mémoire pendant l'encodage : à surveiller à 16K.
public enum JPEGWriter {
    public enum Failure: Error {
        case encoderUnavailable
        case encodingFailed
    }

    public static func write(to url: URL, width: Int, height: Int, quality: Double, bandHeight: Int = 256,
                             rows: @escaping RowProvider, progress: @escaping ExportProgress = { _ in true }) throws {
        guard width > 0, height > 0 else { throw ExportError.invalidDimensions }
        let feeder = RowFeeder(width: width, height: height, bandHeight: bandHeight, rows: rows, progress: progress)
        var callbacks = CGDataProviderSequentialCallbacks(
            version: 0,
            getBytes: { info, buffer, count in
                Unmanaged<RowFeeder>.fromOpaque(info!).takeUnretainedValue().read(into: buffer, count: count)
            },
            skipForward: { info, count in
                Unmanaged<RowFeeder>.fromOpaque(info!).takeUnretainedValue().skip(Int(count))
            },
            rewind: { info in
                Unmanaged<RowFeeder>.fromOpaque(info!).takeUnretainedValue().rewind()
            },
            releaseInfo: { info in
                Unmanaged<RowFeeder>.fromOpaque(info!).release()
            })
        let info = Unmanaged.passRetained(feeder).toOpaque()
        guard let provider = CGDataProvider(sequentialInfo: info, callbacks: &callbacks),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw Failure.encoderUnavailable }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        let finished = CGImageDestinationFinalize(destination)
        if feeder.cancelled {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.cancelled
        }
        if let error = feeder.error {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        guard finished else {
            try? FileManager.default.removeItem(at: url)
            throw Failure.encodingFailed
        }
    }
}

/// Produit les octets RGBX 8 bits d'une image bande par bande, pour un `CGDataProvider` séquentiel.
private final class RowFeeder {
    let width: Int
    let height: Int
    let bandHeight: Int
    let rows: RowProvider
    let progress: ExportProgress
    private var band: [UInt8] = []
    private var bandOffset = 0
    private var nextY = 0
    var cancelled = false
    var error: (any Error)?

    init(width: Int, height: Int, bandHeight: Int, rows: @escaping RowProvider, progress: @escaping ExportProgress) {
        self.width = width
        self.height = height
        self.bandHeight = bandHeight
        self.rows = rows
        self.progress = progress
    }

    /// Prépare la bande suivante ; faux en fin d'image, sur erreur ou annulation.
    private func refill() -> Bool {
        guard nextY < height, !cancelled, error == nil else { return false }
        let count = min(bandHeight, height - nextY)
        do {
            let pixels = try rows(nextY, count)
            band = [UInt8](repeating: 255, count: pixels.count * 4)
            for (i, p) in pixels.enumerated() {
                band[i * 4] = UInt8(min(1, max(0, p.x)) * 255 + 0.5)
                band[i * 4 + 1] = UInt8(min(1, max(0, p.y)) * 255 + 0.5)
                band[i * 4 + 2] = UInt8(min(1, max(0, p.z)) * 255 + 0.5)
            }
        } catch {
            self.error = error
            return false
        }
        bandOffset = 0
        nextY += count
        if !progress(Double(nextY) / Double(height)) { cancelled = true }
        return true
    }

    func read(into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        var written = 0
        while written < count {
            if bandOffset >= band.count, !refill() { break }
            let n = min(count - written, band.count - bandOffset)
            band.withUnsafeBytes { src in
                (buffer + written).copyMemory(from: src.baseAddress! + bandOffset, byteCount: n)
            }
            bandOffset += n
            written += n
        }
        return written
    }

    func skip(_ count: Int) -> off_t {
        var skipped = 0
        while skipped < count {
            if bandOffset >= band.count, !refill() { break }
            let n = min(count - skipped, band.count - bandOffset)
            bandOffset += n
            skipped += n
        }
        return off_t(skipped)
    }

    func rewind() {
        nextY = 0
        band = []
        bandOffset = 0
    }
}
