import Foundation
import PRCore

/// Les projets d'un dossier (la galerie) : noms uniques, duplication, renommage, suppression et instantanés.
/// Les instantanés d'un projet `Nom.prrange` vivent à côté, dans `Nom.instantanes/` : l'enregistrement remplace
/// le paquet du projet en entier, ils ne peuvent donc pas être dedans.
public struct ProjectLibrary: Sendable {
    public static let fileExtension = "prrange"
    public static let snapshotsSuffix = "instantanes"
    public static let thumbnailName = "vignette.jpg"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public struct Snapshot: Sendable, Identifiable, Hashable {
        public let url: URL
        public let date: Date
        public var id: URL { url }
        public var name: String { url.deletingPathExtension().lastPathComponent }
    }

    /// Nom de fichier sans caractères interdits ; « Sans titre » s'il est vide.
    public static func sanitized(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Sans titre" : cleaned
    }

    public func url(for name: String) -> URL {
        directory.appendingPathComponent(Self.sanitized(name)).appendingPathExtension(Self.fileExtension)
    }

    /// `Nom`, sinon `Nom 2`, `Nom 3`… (en ignorant `except`, le projet lui-même lors d'un renommage).
    public func uniqueURL(for name: String, except: URL? = nil) -> URL {
        let base = Self.sanitized(name)
        var candidate = url(for: base)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path), candidate.standardizedFileURL != except?.standardizedFileURL {
            candidate = url(for: "\(base) \(n)")
            n += 1
        }
        return candidate
    }

    public func snapshotsDirectory(for project: URL) -> URL {
        project.deletingPathExtension().appendingPathExtension(Self.snapshotsSuffix)
    }

    public func projects() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == Self.fileExtension }
    }

    /// Copie complète (instantanés compris) sous « Nom copie ».
    @discardableResult
    public func duplicate(_ project: URL) throws -> URL {
        let target = uniqueURL(for: project.deletingPathExtension().lastPathComponent + " copie")
        try FileManager.default.copyItem(at: project, to: target)
        let snapshots = snapshotsDirectory(for: project)
        if FileManager.default.fileExists(atPath: snapshots.path) {
            try FileManager.default.copyItem(at: snapshots, to: snapshotsDirectory(for: target))
        }
        return target
    }

    /// Renomme le projet et ses instantanés ; renvoie la nouvelle adresse (numérotée si le nom est pris).
    @discardableResult
    public func rename(_ project: URL, to name: String) throws -> URL {
        let target = uniqueURL(for: name, except: project)
        guard target.standardizedFileURL != project.standardizedFileURL else { return project }
        try FileManager.default.moveItem(at: project, to: target)
        let snapshots = snapshotsDirectory(for: project)
        if FileManager.default.fileExists(atPath: snapshots.path) {
            try FileManager.default.moveItem(at: snapshots, to: snapshotsDirectory(for: target))
        }
        return target
    }

    public func delete(_ project: URL) throws {
        try FileManager.default.removeItem(at: project)
        let snapshots = snapshotsDirectory(for: project)
        if FileManager.default.fileExists(atPath: snapshots.path) { try FileManager.default.removeItem(at: snapshots) }
    }

    // MARK: - Instantanés

    public func snapshots(of project: URL) -> [Snapshot] {
        let folder = snapshotsDirectory(for: project)
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls.filter { $0.pathExtension == Self.fileExtension }
            .map { url in
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return Snapshot(url: url, date: date)
            }
            .sorted { $0.date > $1.date }
    }

    /// Enregistre l'état actuel de la pile comme instantané nommé du projet.
    @discardableResult
    public func createSnapshot(named name: String, stack: LayerStack, of project: URL, createdAt: Date) throws -> Snapshot {
        let folder = snapshotsDirectory(for: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let inner = ProjectLibrary(directory: folder)
        let url = inner.uniqueURL(for: name)
        try ProjectPackage.save(stack: stack, to: url, createdAt: createdAt)
        return Snapshot(url: url, date: Date())
    }

    public func deleteSnapshot(_ snapshot: Snapshot) throws {
        try FileManager.default.removeItem(at: snapshot.url)
    }
}
