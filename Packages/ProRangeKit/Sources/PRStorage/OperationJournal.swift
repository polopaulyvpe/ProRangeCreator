import Foundation
import PRCore

/// Journal binaire des opérations (traits, gommes…), pour le timelapse et la relecture. L'annulation passe par `UndoRedoManager` (deltas de tuiles).
/// Format : [Magic(4)][Version(1)][Reserved(3)] [Op1][Op2]...
/// Chaque opération : [Tag(1)][Length(4)][Payload...]
public final class OperationJournal {
    public let url: URL
    public private(set) var currentIndex: Int = 0

    private let fileHandle: FileHandle
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // Magic bytes: "PRJL" = ProRange JournaL
    private static let magic = Data([0x50, 0x52, 0x4A, 0x4C])
    private static let version: UInt8 = 1

    public init(url: URL) throws {
        self.url = url
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601

        if FileManager.default.fileExists(atPath: url.path) {
            self.fileHandle = try FileHandle(forUpdating: url)
            try fileHandle.seekToEnd()
            // Lire l'index actuel (nombre d'opérations)
            currentIndex = try countOperations()
        } else {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            self.fileHandle = try FileHandle(forUpdating: url)
            // Écrire l'en-tête
            var header = Self.magic
            header.append(Self.version)
            header.append(contentsOf: [0, 0, 0]) // reserved
            try fileHandle.write(contentsOf: header)
        }
    }

    deinit {
        try? fileHandle.close()
    }

    // MARK: - Écriture d'opérations

    /// Ajoute une opération de pinceau (StrokeOp).
    /// `centers` : centres des dabs en coordonnées sphériques (Vec3).
    /// `radius` : rayon angulaire en radians.
    /// `hardness` : 0-1.
    /// `color` : RGBA linéaire prémultiplié.
    /// `spacing` : espacement angulaire entre dabs (radians).
    /// `screenSpace` : true si empreinte écran (pas sphérique).
    public func appendStroke(
        centers: [Vec3],
        radius: Double,
        hardness: Double,
        color: SIMD4<Float>,
        spacing: Double,
        screenSpace: Bool
    ) throws {
        let op = StrokeOp(
            centers: centers.map { [$0.x, $0.y, $0.z] },
            radius: radius,
            hardness: hardness,
            color: [color.x, color.y, color.z, color.w],
            spacing: spacing,
            screenSpace: screenSpace
        )
        try writeOperation(tag: 0x01, payload: try encoder.encode(op))
    }

    /// Ajoute une opération de gomme (EraseOp).
    /// Même structure que StrokeOp mais color est ignoré (alpha = 0).
    public func appendErase(
        centers: [Vec3],
        radius: Double,
        hardness: Double,
        spacing: Double,
        screenSpace: Bool
    ) throws {
        let op = EraseOp(
            centers: centers.map { [$0.x, $0.y, $0.z] },
            radius: radius,
            hardness: hardness,
            spacing: spacing,
            screenSpace: screenSpace
        )
        try writeOperation(tag: 0x02, payload: try encoder.encode(op))
    }

    /// Ajoute une opération de remplissage (FillOp).
    /// Remplit une région connectée à partir d'un point de départ (flood fill sphérique).
    /// `start` : direction de départ.
    /// `tolerance` : tolérance angulaire en radians pour la similarité de couleur.
    /// `color` : nouvelle couleur (RGBA linéaire prémultiplié).
    public func appendFill(
        start: Vec3,
        tolerance: Double,
        color: SIMD4<Float>
    ) throws {
        let op = FillOp(
            start: [start.x, start.y, start.z],
            tolerance: tolerance,
            color: [color.x, color.y, color.z, color.w]
        )
        try writeOperation(tag: 0x03, payload: try encoder.encode(op))
    }

    /// Ajoute une opération de transformation (TransformOp).
    /// Rotation/translation de la toile ou d'une sélection.
    /// Pour l'instant : rotation globale (matrice 3x3).
    public func appendTransform(
        matrix: [[Double]], // 3x3 row-major
        affectedTiles: [TileCoord]? = nil
    ) throws {
        let op = TransformOp(
            matrix: matrix,
            affectedTiles: affectedTiles
        )
        try writeOperation(tag: 0x04, payload: try encoder.encode(op))
    }

    /// Ajoute un marqueur de checkpoint.
    public func appendCheckpoint(name: String, index: Int) throws {
        let op = CheckpointOp(name: name, journalIndex: index)
        try writeOperation(tag: 0xFF, payload: try encoder.encode(op))
    }

    private func writeOperation(tag: UInt8, payload: Data) throws {
        try fileHandle.seekToEnd()
        var buffer = Data()
        buffer.append(tag)
        let length = UInt32(payload.count)
        buffer.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Array($0) })
        buffer.append(payload)
        try fileHandle.write(contentsOf: buffer)
        currentIndex += 1
    }

    // MARK: - Lecture / Replay

    /// Rejoue toutes les opérations depuis le début (ou depuis `fromIndex`) en appelant `handler` pour chacune.
    /// Retourne le nombre d'opérations rejouées.
    public func replay(fromIndex: Int = 0, handler: (Operation) async throws -> Void) async throws -> Int {
        try fileHandle.seek(toOffset: headerSize)
        var index = 0
        var replayed = 0

        while true {
            var tagByte: UInt8 = 0
            let tagRead = try fileHandle.read(upToCount: 1)
            guard let tagData = tagRead, tagData.count == 1 else { break }
            tagByte = tagData[0]

            let lengthData = try fileHandle.read(upToCount: 4)
            guard let lenData = lengthData, lenData.count == 4 else { break }
            let length = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }

            let payloadData = try fileHandle.read(upToCount: Int(length))
            guard let payload = payloadData, payload.count == length else { break }

            if index >= fromIndex {
                let op = try decodeOperation(tag: tagByte, payload: payload)
                try await handler(op)
                replayed += 1
            }
            index += 1
        }
        return replayed
    }

    /// Lit une opération à un index spécifique (pour inspection/débogage).
    public func operation(at index: Int) throws -> Operation? {
        try fileHandle.seek(toOffset: headerSize)
        var current = 0

        while current <= index {
            var tagByte: UInt8 = 0
            let tagRead = try fileHandle.read(upToCount: 1)
            guard let tagData = tagRead, tagData.count == 1 else { return nil }
            tagByte = tagData[0]

            let lengthData = try fileHandle.read(upToCount: 4)
            guard let lenData = lengthData, lenData.count == 4 else { return nil }
            let length = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }

            let payloadData = try fileHandle.read(upToCount: Int(length))
            guard let payload = payloadData, payload.count == length else { return nil }

            if current == index {
                return try decodeOperation(tag: tagByte, payload: payload)
            }
            current += 1
        }
        return nil
    }

    /// Tronque le journal après l'index donné (garde les opérations 0..toIndex-1).
    public func truncate(to toIndex: Int) throws {
        // Stratégie : réécrire le fichier complet (plus simple et sûr pour un journal append-only)
        var operations: [Data] = []
        try fileHandle.seek(toOffset: headerSize)
        var index = 0

        while true {
            var tagByte: UInt8 = 0
            let tagRead = try fileHandle.read(upToCount: 1)
            guard let tagData = tagRead, tagData.count == 1 else { break }
            tagByte = tagData[0]

            let lengthData = try fileHandle.read(upToCount: 4)
            guard let lenData = lengthData, lenData.count == 4 else { break }
            let length = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }

            let payloadData = try fileHandle.read(upToCount: Int(length))
            guard let payload = payloadData, payload.count == length else { break }

            if index < toIndex {
                var buf = Data()
                buf.append(tagByte)
                buf.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Array($0) })
                buf.append(payload)
                operations.append(buf)
            }
            index += 1
        }

        // Réécrire
        try fileHandle.truncate(atOffset: 0)
        var header = Self.magic
        header.append(Self.version)
        header.append(contentsOf: [0, 0, 0])
        try fileHandle.write(contentsOf: header)
        for opData in operations {
            try fileHandle.write(contentsOf: opData)
        }
        try fileHandle.synchronize()
        currentIndex = toIndex
    }

    /// Compte le nombre d'opérations dans le journal.
    private func countOperations() throws -> Int {
        try fileHandle.seek(toOffset: headerSize)
        var count = 0
        while true {
            let tagRead = try fileHandle.read(upToCount: 1)
            guard let tagData = tagRead, tagData.count == 1 else { break }
            let lengthData = try fileHandle.read(upToCount: 4)
            guard let lenData = lengthData, lenData.count == 4 else { break }
            let length = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
            let _ = try fileHandle.read(upToCount: Int(length))
            count += 1
        }
        return count
    }

    private var headerSize: UInt64 { 8 } // 4 magic + 1 version + 3 reserved

    private func decodeOperation(tag: UInt8, payload: Data) throws -> Operation {
        switch tag {
        case 0x01: return .stroke(try decoder.decode(StrokeOp.self, from: payload))
        case 0x02: return .erase(try decoder.decode(EraseOp.self, from: payload))
        case 0x03: return .fill(try decoder.decode(FillOp.self, from: payload))
        case 0x04: return .transform(try decoder.decode(TransformOp.self, from: payload))
        case 0xFF: return .checkpoint(try decoder.decode(CheckpointOp.self, from: payload))
        default: throw OperationJournalError.unknownTag(tag)
        }
    }

    /// Vérifie l'intégrité du journal.
    public func verify() -> VerificationResult {
        var errors: [String] = []
        var warnings: [String] = []

        do {
            try fileHandle.seek(toOffset: headerSize)
            var index = 0
            while true {
                let tagRead = try fileHandle.read(upToCount: 1)
                guard let tagData = tagRead, tagData.count == 1 else { break }
                let lengthData = try fileHandle.read(upToCount: 4)
                guard let lenData = lengthData, lenData.count == 4 else {
                    errors.append("Op \(index): longueur tronquée")
                    break
                }
                let length = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
                let payloadData = try fileHandle.read(upToCount: Int(length))
                guard let payload = payloadData, payload.count == length else {
                    errors.append("Op \(index): payload tronqué (attendu \(length), lu \(payloadData?.count ?? 0))")
                    break
                }
                // Tenter de décoder
                let tag = tagData[0]
                do {
                    _ = try decodeOperation(tag: tag, payload: payload)
                } catch {
                    errors.append("Op \(index): décodage échoué - \(error)")
                }
                index += 1
            }
        } catch {
            errors.append("Erreur lecture journal: \(error)")
        }

        return VerificationResult(errors: errors, warnings: warnings)
    }

    public struct VerificationResult: Sendable {
        public let errors: [String]
        public let warnings: [String]
        public var isValid: Bool { errors.isEmpty }
    }

    public enum OperationJournalError: Error, CustomStringConvertible {
        case unknownTag(UInt8)
        case truncated
        case invalidPayload

        public var description: String {
            switch self {
            case .unknownTag(let t): return "Tag d'opération inconnu: 0x\(String(t, radix: 16))"
            case .truncated: return "Journal tronqué"
            case .invalidPayload: return "Payload invalide"
            }
        }
    }
}

// MARK: - Types d'opérations (Codable pour le payload JSON)

public enum Operation: Sendable {
    case stroke(StrokeOp)
    case erase(EraseOp)
    case fill(FillOp)
    case transform(TransformOp)
    case checkpoint(CheckpointOp)
}

/// Pinceau : liste de centres de dabs (Vec3), rayon, dureté, couleur, espacement.
public struct StrokeOp: Codable, Sendable {
    public let centers: [[Double]] // [ [x,y,z], ... ]
    public let radius: Double
    public let hardness: Double
    public let color: [Float] // RGBA linéaire prémultiplié
    public let spacing: Double
    public let screenSpace: Bool

    public var vec3Centers: [Vec3] {
        centers.map { Vec3($0[0], $0[1], $0[2]) }
    }
    public var simdColor: SIMD4<Float> {
        SIMD4<Float>(color[0], color[1], color[2], color[3])
    }
}

/// Gomme : comme StrokeOp mais sans couleur (alpha = 0 implicite).
public struct EraseOp: Codable, Sendable {
    public let centers: [[Double]]
    public let radius: Double
    public let hardness: Double
    public let spacing: Double
    public let screenSpace: Bool

    public var vec3Centers: [Vec3] {
        centers.map { Vec3($0[0], $0[1], $0[2]) }
    }
}

/// Remplissage (flood fill sphérique).
public struct FillOp: Codable, Sendable {
    public let start: [Double] // Vec3
    public let tolerance: Double // radians
    public let color: [Float] // RGBA

    public var vec3Start: Vec3 { Vec3(start[0], start[1], start[2]) }
    public var simdColor: SIMD4<Float> { SIMD4<Float>(color[0], color[1], color[2], color[3]) }
}

/// Transformation (rotation globale 3x3 pour l'instant).
public struct TransformOp: Codable, Sendable {
    public let matrix: [[Double]] // 3x3 row-major
    public let affectedTiles: [TileCoord]? // Tuiles potentiellement affectées

    public var tileCoords: [TileCoord] {
        affectedTiles ?? []
    }
}

/// Marqueur de checkpoint.
public struct CheckpointOp: Codable, Sendable {
    public let name: String
    public let journalIndex: Int
}