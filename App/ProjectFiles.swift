import Foundation
import PRCore
import PRImaging
import PRStorage
import SwiftUI

/// Drapeau d'annulation partagé avec la tâche d'export en arrière-plan.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// La pile passe à la tâche d'export : la feuille d'export est modale, personne ne peint pendant ce temps.
private struct UncheckedStack: @unchecked Sendable {
    let stack: LayerStack
    let space: BlendSpace
}

struct ProjectInfo: Identifiable, Hashable {
    let url: URL
    let modified: Date
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum ExportKind: String, CaseIterable {
    case exr
    case hdr

    var label: String { self == .exr ? "OpenEXR (.exr)" : "Radiance (.hdr)" }
}

extension CanvasSession {
    /// Projets dans Documents (visibles aussi dans l'app Fichiers).
    static var projectsDirectory: URL {
        let url = URL.documentsDirectory.appendingPathComponent("Projets", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var exportsDirectory: URL {
        let url = URL.documentsDirectory.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func listProjects() -> [ProjectInfo] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.projectsDirectory,
                                                                 includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "prrange" }
            .map { url in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return ProjectInfo(url: url, modified: date)
            }
            .sorted { $0.modified > $1.modified }
    }

    func newProject() {
        replaceStack(LayerStack(width: Self.canvasWidth, height: Self.canvasWidth / 2))
        projectName = "Sans titre"
        projectCreatedAt = Date()
        fileMessage = nil
    }

    func saveProject() {
        strokeCancelled()
        let url = Self.projectsDirectory.appendingPathComponent("\(sanitized(projectName)).prrange")
        do {
            try ProjectPackage.save(stack: stack, to: url, createdAt: projectCreatedAt)
            fileMessage = "Enregistré : \(url.lastPathComponent)"
        } catch {
            fileMessage = "Échec de l'enregistrement : \(error.localizedDescription)"
        }
    }

    func openProject(_ project: ProjectInfo) {
        do {
            let (manifest, loaded) = try ProjectPackage.loadStack(from: project.url)
            replaceStack(loaded)
            projectName = project.name
            projectCreatedAt = manifest.createdAt
            fileMessage = "Ouvert : \(project.name)"
        } catch {
            fileMessage = "Impossible d'ouvrir \(project.name) : \(error)"
        }
    }

    func deleteProject(_ project: ProjectInfo) {
        try? FileManager.default.removeItem(at: project.url)
    }

    func startExport(format: PanoramaFormat, options: PanoramaExportOptions) {
        guard !isExporting else { return }
        strokeCancelled()
        let suffix = options.downscale == 1 ? "" : "-\(stack.width / options.downscale / 1024)K"
        let url = Self.exportsDirectory.appendingPathComponent("\(sanitized(projectName))\(suffix).\(format.fileExtension)")
        let cancel = CancelFlag()
        let job = UncheckedStack(stack: stack, space: blendSpace)
        exportCancel = cancel
        isExporting = true
        exportProgress = 0
        lastExportURL = nil
        Task.detached(priority: .userInitiated) {
            let result: Result<URL, Error>
            do {
                try PanoramaExporter.export(job.stack, as: format, options: options, space: job.space, to: url) { progress in
                    Task { @MainActor in self.exportProgress = progress }
                    return !cancel.isCancelled
                }
                result = .success(url)
            } catch {
                result = .failure(error)
            }
            await MainActor.run { self.finishExport(result) }
        }
    }

    func cancelExport() {
        exportCancel?.cancel()
    }

    private func finishExport(_ result: Result<URL, Error>) {
        isExporting = false
        exportCancel = nil
        switch result {
        case .success(let url):
            lastExportURL = url
            fileMessage = "Exporté : \(url.lastPathComponent)"
        case .failure(let error as ExportError) where error == .cancelled:
            fileMessage = "Export annulé"
        case .failure(let error):
            fileMessage = "Échec de l'export : \(error)"
        }
    }

    private func sanitized(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Sans titre" : cleaned
    }
}

struct FileMenu: View {
    @Bindable var session: CanvasSession

    var body: some View {
        Menu("Fichier", systemImage: "folder") {
            Button("Nouveau", systemImage: "doc") { session.newProject() }
            Button("Enregistrer", systemImage: "square.and.arrow.down") { session.saveProject() }
            Button("Ouvrir…", systemImage: "folder") { session.showProjects = true }
            Divider()
            Button("Exporter…", systemImage: "square.and.arrow.up") { session.showExport = true }
        }
        .sheet(isPresented: $session.showProjects) { ProjectsSheet(session: session) }
        .sheet(isPresented: $session.showExport) { ExportSheet(session: session) }
    }
}

struct ProjectsSheet: View {
    @Bindable var session: CanvasSession
    @Environment(\.dismiss) private var dismiss
    @State private var projects: [ProjectInfo] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Nom du projet en cours") {
                    TextField("Nom", text: $session.projectName)
                }
                Section("Projets enregistrés") {
                    if projects.isEmpty { Text("Aucun projet pour l'instant").foregroundStyle(.secondary) }
                    ForEach(projects) { project in
                        Button {
                            session.openProject(project)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(project.name)
                                Text(project.modified, style: .relative).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { session.deleteProject(projects[i]) }
                        projects = session.listProjects()
                    }
                }
            }
            .navigationTitle("Projets")
            .toolbar { Button("Fermer") { dismiss() } }
            .onAppear { projects = session.listProjects() }
        }
    }
}

struct ExportSheet: View {
    @Bindable var session: CanvasSession
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ExportKind = .exr
    @State private var pixelType: EXRPixelType = .half
    @State private var compression: EXRCompression = .zip
    @State private var includeAlpha = false
    @State private var includePaper = true
    @State private var downscale = 1

    private var format: PanoramaFormat {
        kind == .hdr ? .hdr : .exr(pixelType, compression, includeAlpha: includeAlpha)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Format") {
                    Picker("Format", selection: $kind) {
                        ForEach(ExportKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if kind == .exr {
                        Picker("Précision", selection: $pixelType) {
                            ForEach(EXRPixelType.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        Picker("Compression", selection: $compression) {
                            ForEach(EXRCompression.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        Toggle("Canal alpha (RGBA)", isOn: $includeAlpha)
                    }
                }
                Section("Image") {
                    Picker("Résolution", selection: $downscale) {
                        ForEach([1, 2, 4, 8], id: \.self) { f in
                            Text("\(session.stack.width / f) × \(session.stack.height / f)").tag(f)
                        }
                    }
                    Toggle("Papier blanc sous la peinture", isOn: $includePaper)
                    if !includePaper {
                        Text("Fond transparent : les zones non peintes sont noires en HDR, transparentes en EXR RGBA.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    if session.isExporting {
                        ProgressView(value: session.exportProgress)
                        Button("Annuler l'export", role: .destructive) { session.cancelExport() }
                    } else {
                        Button("Exporter", systemImage: "square.and.arrow.up") {
                            session.startExport(format: format,
                                                options: PanoramaExportOptions(downscale: downscale, paper: includePaper ? [1, 1, 1] : nil))
                        }
                    }
                    if let url = session.lastExportURL {
                        ShareLink(item: url) {
                            Label("Partager ou enregistrer dans Fichiers", systemImage: "square.and.arrow.up.on.square")
                        }
                    }
                    if let message = session.fileMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Exporter la HDRI")
            .toolbar { Button("Fermer") { dismiss() }.disabled(session.isExporting) }
        }
        .interactiveDismissDisabled(session.isExporting)
    }
}
