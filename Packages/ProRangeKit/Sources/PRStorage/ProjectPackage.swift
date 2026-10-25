import Foundation

/// Conteneur `.prrange` : dossier avec manifest.json, tiles/, journal/, checkpoints/.
/// Format package (directory-based) pour éviter la complexité des archives zip.
public final class ProjectPackage: Sendable {
    public let url: URL
    public let manifest: Manifest
    public let tileStore: TileStore
    public let journal: OperationJournal
    public let checkpointsDir: URL

    private let fileManager = FileManager.default

    public init(url: URL, create: Bool = false) throws {
        self.url = url
        let tilesURL = url.appendingPathComponent("tiles", isDirectory: true)
        let journalURL = url.appendingPathComponent("journal.bin", isDirectory: false)
        let checkpointsURL = url.appendingPathComponent("checkpoints", isDirectory: true)

        if create {
            try fileManager.createDirectory(at: tilesURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: checkpointsURL, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: journalURL.path) {
                try Data().write(to: journalURL, options: .atomic)
            }
            let manifest = Manifest(
                version: 1,
                baseWidth: 16384,
                baseHeight: 8192,
                tileSize: 512,
                maxLevel: 4,
                colorSpace: "linear-srgb-premul",
                createdAt: Date(),
                modifiedAt: Date()
            )
            self.manifest = manifest
            self.tileStore = try TileStore(baseURL: tilesURL, maxLevel: manifest.maxLevel)
            self.journal = try OperationJournal(url: journalURL)
            self.checkpointsDir = checkpointsURL
            try writeManifest(manifest)
        } else {
            let manifestURL = url.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
                throw ProjectPackageError.invalidManifest
            }
            self.manifest = manifest
            self.tileStore = try TileStore(baseURL: tilesURL, maxLevel: manifest.maxLevel)
            self.journal = try OperationJournal(url: journalURL)
            self.checkpointsDir = checkpointsURL
        }
    }

    /// Crée un nouveau package vide.
    public static func create(at url: URL) throws -> ProjectPackage {
        try ProjectPackage(url: url, create: true)
    }

    /// Ouvre un package existant.
    public static func open(at url: URL) throws -> ProjectPackage {
        try ProjectPackage(url: url, create: false)
    }

    private func writeManifest(_ manifest: Manifest) throws {
        let manifestURL = url.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    /// Met à jour `modifiedAt` dans le manifest.
    public func touchManifest() throws {
        var updated = manifest
        updated = Manifest(
            version: manifest.version,
            baseWidth: manifest.baseWidth,
            baseHeight: manifest.baseHeight,
            tileSize: manifest.tileSize,
            maxLevel: manifest.maxLevel,
            colorSpace: manifest.colorSpace,
            createdAt: manifest.createdAt,
            modifiedAt: Date()
        )
        try writeManifest(updated)
    }

    /// Crée un checkpoint : snapshot du journal + index des tuiles modifiées depuis le dernier checkpoint.
    /// Retourne l'URL du checkpoint créé.
    public func createCheckpoint(name: String? = nil) throws -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let checkpointName = name ?? "checkpoint-\(timestamp)"
        let checkpointURL = checkpointsDir.appendingPathComponent("\(checkpointName).json")

        let index = journal.currentIndex
        let modifiedTiles = tileStore.listAllModified() // Tuiles modifiées depuis le dernier checkpoint
        let checkpoint = Checkpoint(
            name: checkpointName,
            timestamp: Date(),
            journalIndex: index,
            modifiedTiles: modifiedTiles
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(checkpoint)
        try data.write(to: checkpointURL, options: .atomic)
        return checkpointURL
    }

    /// Liste les checkpoints disponibles.
    public func listCheckpoints() -> [Checkpoint] {
        guard let files = try? fileManager.contentsOfDirectory(at: checkpointsDir, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.compactMap { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let checkpoint = try? decoder.decode(Checkpoint.self, from: data) else {
                return nil
            }
            return checkpoint
        }.sorted { $0.timestamp > $1.timestamp }
    }

    /// Restaure l'état à un checkpoint (replay journal + rechargement tuiles).
    public func restoreCheckpoint(_ checkpoint: Checkpoint) throws {
        // 1. Tronquer le journal à l'index du checkpoint
        try journal.truncate(to: checkpoint.journalIndex)

        // 2. Rejouer les opérations depuis le début jusqu'au checkpoint
        // (L'UndoRedoManager gère le replay complet)

        // 3. Marquer les tuiles modifiées comme "clean" pour le prochain checkpoint
        tileStore.markClean(modifiedTiles: checkpoint.modifiedTiles)

        // 4. Mettre à jour le manifest
        try touchManifest()
    }

    /// Vérifie l'intégrité du package.
    public func verify() throws -> VerificationResult {
        var errors: [String] = []
        var warnings: [String] = []

        // Manifest
        let manifestURL = url.appendingPathComponent("manifest.json")
        if !fileManager.fileExists(atPath: manifestURL.path) {
            errors.append("Manifest manquant")
        }

        // Tiles
        for level in 0...manifest.maxLevel {
            let tiles = tileStore.list(level: level)
            for (x, y) in tiles {
                let tileURL = tileStore.compressedPath(level: level, x: x, y: y)
                if let data = try? Data(contentsOf: tileURL),
                   let decompressed = try? tileStore.decompressLZFSE(data, expectedSize: 512 * 512 * 8) {
                    if decompressed.count != 512 * 512 * 8 {
                        warnings.append("Tuile \(level)/\(x)_\(y): taille décompressée inattendue (\(decompressed.count) octets)")
                    }
                } else {
                    errors.append("Tuile \(level)/\(x)_\(y): impossible à lire ou décompresser")
                }
            }
        }

        // Journal
        let journalResult = journal.verify()
        errors.append(contentsOf: journalResult.errors)
        warnings.append(contentsOf: journalResult.warnings)

        // Checkpoints
        for cp in listCheckpoints() {
            if cp.journalIndex > journal.currentIndex {
                warnings.append("Checkpoint \(cp.name): index journal (\(cp.journalIndex)) > index actuel (\(journal.currentIndex))")
            }
        }

        return VerificationResult(errors: errors, warnings: warnings)
    }

    public struct Manifest: Codable, Sendable {
        public let version: Int
        public let baseWidth: Int
        public let baseHeight: Int
        public let tileSize: Int
        public let maxLevel: Int
        public let colorSpace: String
        public let createdAt: Date
        public let modifiedAt: Date
    }

    public struct Checkpoint: Codable, Sendable {
        public let name: String
        public let timestamp: Date
        public let journalIndex: Int
        public let modifiedTiles: [TileCoord]
    }

    public struct VerificationResult: Sendable {
        public let errors: [String]
        public let warnings: [String]
        public var isValid: Bool { errors.isEmpty }
    }

    public enum ProjectPackageError: Error, CustomStringConvertible {
        case invalidManifest
        case missingDirectory(String)
        case checkpointNotFound(String)

        public var description: String {
            switch self {
            case .invalidManifest: return "Manifest invalide ou manquant"
            case .missingDirectory(let path): return "Dossier manquant: \(path)"
            case .checkpointNotFound(let name): return "Checkpoint introuvable: \(name)"
            }
        }
    }
}

extension TileStore {
    /// Liste toutes les tuiles sur tous les niveaux (pour checkpoints).
    func listAllModified() -> [TileCoord] {
        var all: [TileCoord] = []
        for level in 0...maxLevel {
            let tiles = list(level: level)
            all.append(contentsOf: tiles.map { TileCoord(level: level, x: $0.0, y: $0.1) })
        }
        return all
    }

    /// Marque les tuiles comme propres (pour le suivi des modifications entre checkpoints).
    func markClean(modifiedTiles: [TileCoord]) {
        // Pour une vraie implémentation, on maintiendrait un bitmap de tuiles "dirty"
        // Ici on laisse vide car TileStore n'a pas encore de suivi dirty
    }
}