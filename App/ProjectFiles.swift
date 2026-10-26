import Foundation
import PRCore
import PRImaging
import PRStorage
import SwiftUI
import UIKit

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
    case png
    case jpeg
    case tiff

    var label: String {
        switch self {
        case .exr: "OpenEXR (.exr)"
        case .hdr: "Radiance (.hdr)"
        case .png: "PNG"
        case .jpeg: "JPG"
        case .tiff: "TIFF flottant"
        }
    }
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

    static var library: ProjectLibrary { ProjectLibrary(directory: projectsDirectory) }
    private static let lastProjectKey = "dernierProjet"

    func newProject() {
        if hasUnsavedChanges { saveProject(silently: true) }
        replaceStack(LayerStack(width: preferences.canvasWidth, height: preferences.canvasWidth / 2))
        setBlendSpace(preferences.blendSpace)
        projectName = "Sans titre"
        projectURL = nil
        projectCreatedAt = Date()
        hasUnsavedChanges = false
        fileMessage = nil
        // Nouveau projet : timelapse dans un dossier de travail neuf (celui du projet précédent reste à côté de lui).
        timelapseRecorder?.switchTo(URL.cachesDirectory.appendingPathComponent("Timelapse/\(UUID().uuidString)", isDirectory: true))
        timelapseFrames = 0
    }

    /// Enregistre dans le fichier du projet (créé au premier enregistrement, renommé si le nom a changé),
    /// avec la vignette de la galerie et le timelapse.
    func saveProject(silently: Bool = false) {
        strokeCancelled()
        let library = Self.library
        do {
            var url = projectURL ?? library.uniqueURL(for: projectName)
            if projectURL != nil, url.deletingPathExtension().lastPathComponent != ProjectLibrary.sanitized(projectName) {
                url = try library.rename(url, to: projectName)
            }
            try ProjectPackage.save(stack: stack, to: url, createdAt: projectCreatedAt)
            // Le timelapse vit à côté du paquet : déplacé au premier enregistrement, jamais recopié ensuite.
            try timelapseRecorder?.relocate(to: library.timelapseDirectory(for: url))
            // Vignette de la galerie, rendue à l'enregistrement seulement (pas après chaque opération).
            if let rgba = renderUnfolded(width: 640, height: 320) {
                TimelapseRecorder.writeJPEG(rgba, width: 640, height: 320, to: url.appendingPathComponent(ProjectLibrary.thumbnailName))
            }
            projectURL = url
            projectName = url.deletingPathExtension().lastPathComponent
            hasUnsavedChanges = false
            UserDefaults.standard.set(url.lastPathComponent, forKey: Self.lastProjectKey)
            if !silently { fileMessage = "Enregistré : \(projectName)" }
        } catch {
            fileMessage = "Échec de l'enregistrement : \(error.localizedDescription)"
        }
    }

    func openProject(_ project: ProjectInfo) {
        if hasUnsavedChanges, projectURL != project.url { saveProject(silently: true) }
        do {
            let (manifest, loaded) = try ProjectPackage.loadStack(from: project.url)
            replaceStack(loaded)
            projectName = project.name
            projectURL = project.url
            projectCreatedAt = manifest.createdAt
            hasUnsavedChanges = false
            // Le timelapse suit le projet (vide s'il n'en a pas).
            let sibling = Self.library.timelapseDirectory(for: project.url)
            let legacy = project.url.appendingPathComponent("timelapse", isDirectory: true)
            if !FileManager.default.fileExists(atPath: sibling.path), FileManager.default.fileExists(atPath: legacy.path) {
                // Ancien format (timelapse dans le paquet) : sorti une fois pour toutes.
                try? FileManager.default.copyItem(at: legacy, to: sibling)
            }
            timelapseRecorder?.switchTo(sibling)
            timelapseFrames = timelapseRecorder?.frameCount ?? 0
            UserDefaults.standard.set(project.url.lastPathComponent, forKey: Self.lastProjectKey)
            fileMessage = "Ouvert : \(project.name)"
        } catch {
            fileMessage = "Impossible d'ouvrir \(project.name) : \(error)"
        }
    }

    /// Au lancement : rouvre le dernier projet (après un plantage, on perd au plus les 30 s avant la sauvegarde automatique).
    func restoreLastProject() {
        guard projectURL == nil, !hasUnsavedChanges,
              let name = UserDefaults.standard.string(forKey: Self.lastProjectKey) else { return }
        let url = Self.projectsDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        openProject(ProjectInfo(url: url, modified: Date()))
    }

    func deleteProject(_ project: ProjectInfo) {
        try? Self.library.delete(project.url)
        if project.url == projectURL {
            // Supprimé depuis la galerie : il ne doit pas réapparaître à la prochaine sauvegarde automatique.
            projectURL = nil
            autosaveTask?.cancel()
            hasUnsavedChanges = false
            timelapseRecorder?.switchTo(URL.cachesDirectory.appendingPathComponent("Timelapse/\(UUID().uuidString)", isDirectory: true))
        }
    }

    func duplicateProject(_ project: ProjectInfo) {
        if project.url == projectURL, hasUnsavedChanges { saveProject(silently: true) }
        do {
            let copy = try Self.library.duplicate(project.url)
            fileMessage = "Dupliqué : \(copy.deletingPathExtension().lastPathComponent)"
        } catch {
            fileMessage = "Duplication impossible : \(error.localizedDescription)"
        }
    }

    func renameProject(_ project: ProjectInfo, to name: String) {
        do {
            let renamed = try Self.library.rename(project.url, to: name)
            if project.url == projectURL {
                projectURL = renamed
                projectName = renamed.deletingPathExtension().lastPathComponent
                UserDefaults.standard.set(renamed.lastPathComponent, forKey: Self.lastProjectKey)
                timelapseRecorder?.switchTo(Self.library.timelapseDirectory(for: renamed))
            }
        } catch {
            fileMessage = "Renommage impossible : \(error.localizedDescription)"
        }
    }

    // MARK: - Sauvegarde automatique

    /// Appelé après chaque opération : enregistre 30 s après la dernière, sans interrompre un trait ni un outil en cours.
    func scheduleAutosave() {
        hasUnsavedChanges = true
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.autosaveIfIdle()
        }
    }

    private var isBusy: Bool {
        canvas?.isStroking == true || isExporting || activeFilter != nil || transform != nil || distort != nil
    }

    private func autosaveIfIdle() {
        guard hasUnsavedChanges else { return }
        if isBusy {
            scheduleAutosave()
            return
        }
        saveProject(silently: true)
    }

    /// Passage en arrière-plan : enregistrement immédiat, avec du temps demandé au système.
    func saveForBackground() {
        guard hasUnsavedChanges, canvas?.isStroking != true else { return }
        autosaveTask?.cancel()
        let task = UIApplication.shared.beginBackgroundTask(withName: "Sauvegarde")
        saveProject(silently: true)
        UIApplication.shared.endBackgroundTask(task)
    }

    /// Exporte la pile visible (ou le calque actif seul) à une ou plusieurs résolutions.
    func startExport(format: PanoramaFormat, options: PanoramaExportOptions, downscales: [Int], activeLayerOnly: Bool) {
        guard !isExporting, !downscales.isEmpty else { return }
        strokeCancelled()
        var source = stack
        var name = sanitized(projectName)
        if activeLayerOnly, let item = stack.item(activeID), let layer = item.layer {
            source = LayerStack(width: stack.width, height: stack.height, format: layer.format,
                                items: [StackItem(kind: .layer(layer), name: item.name)])
            name += "-" + sanitized(item.name)
        }
        let url = Self.exportsDirectory.appendingPathComponent("\(name).\(format.fileExtension)")
        let cancel = CancelFlag()
        let job = UncheckedStack(stack: source, space: blendSpace)
        exportCancel = cancel
        isExporting = true
        exportProgress = 0
        lastExportURLs = []
        Task.detached(priority: .userInitiated) {
            let result: Result<[URL], Error>
            let report: ExportProgress = { progress in
                Task { @MainActor in self.exportProgress = progress }
                return !cancel.isCancelled
            }
            do {
                if downscales == [1] {
                    var single = options
                    single.downscale = 1
                    result = .success(try PanoramaExporter.export(job.stack, as: format, options: single, space: job.space,
                                                                  to: url, progress: report))
                } else {
                    result = .success(try PanoramaExporter.exportBatch(job.stack, as: format, options: options, downscales: downscales,
                                                                       space: job.space, to: url, progress: report))
                }
            } catch {
                result = .failure(error)
            }
            await MainActor.run { self.finishExport(result) }
        }
    }

    func cancelExport() {
        exportCancel?.cancel()
    }

    private func finishExport(_ result: Result<[URL], Error>) {
        isExporting = false
        exportCancel = nil
        switch result {
        case .success(let urls):
            lastExportURLs = urls
            fileMessage = urls.count == 1 ? "Exporté : \(urls[0].lastPathComponent)" : "Exporté : \(urls.count) fichiers"
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
            Button("Galerie…", systemImage: "square.grid.2x2") { session.showProjects = true }
            Button("Instantanés…", systemImage: "clock.arrow.circlepath") { session.showSnapshots = true }
            Divider()
            ImportMenuItems(session: session)
            Divider()
            Button("Exporter…", systemImage: "square.and.arrow.up") { session.showExport = true }
            Button("Timelapse…", systemImage: "film") { session.showTimelapse = true }
            Divider()
            Button("Préférences…", systemImage: "gearshape") { session.showPreferences = true }
        }
        .sheet(isPresented: $session.showPreferences) { PreferencesSheet(session: session) }
        .sheet(isPresented: $session.showTimelapse) { TimelapseSheet(session: session) }
        .fileImporter(isPresented: $session.showImporter, allowedContentTypes: importableTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { session.loadImport(urls: urls) }
        }
        .sheet(isPresented: $session.showProjects) { GallerySheet(session: session) }
        .sheet(isPresented: $session.showSnapshots) { SnapshotsSheet(session: session) }
        .sheet(isPresented: $session.showExport) { ExportSheet(session: session) }
    }
}

struct ExportSheet: View {
    @Bindable var session: CanvasSession
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ExportKind

    init(session: CanvasSession, kind: ExportKind = .exr) {
        self.session = session
        _kind = State(initialValue: kind)
    }
    @State private var pixelType: EXRPixelType = .half
    @State private var compression: EXRCompression = .zip
    @State private var includeAlpha = false
    @State private var includePaper = true
    @State private var pngDepth = 8
    @State private var tiffDepth = 32
    @State private var jpegQuality = 0.9
    @State private var downscales: Set<Int> = [1]
    @State private var layout: PanoramaLayout = .equirectangular
    @State private var preset: OrientationPreset = .blender
    @State private var extraYaw = 0.0
    @State private var flip = false
    @State private var activeLayerOnly = false
    @State private var exposure = 0.0
    @State private var toneMapping: ToneMapping = .clip
    @State private var upscale = false

    private var upscaling: Bool { upscale && layout == .equirectangular }

    private var format: PanoramaFormat {
        switch kind {
        case .exr: .exr(pixelType, compression, includeAlpha: includeAlpha)
        case .hdr: .hdr
        case .png: .png(bitDepth: pngDepth, includeAlpha: includeAlpha)
        case .jpeg: .jpeg(quality: jpegQuality)
        case .tiff: .tiff(bitsPerSample: tiffDepth, includeAlpha: includeAlpha)
        }
    }

    private var supportsAlpha: Bool { kind == .exr || kind == .png || kind == .tiff }

    private var options: PanoramaExportOptions {
        let base = preset.orientation
        return PanoramaExportOptions(paper: includePaper || kind == .jpeg ? [1, 1, 1] : nil,
                                     orientation: ExportOrientation(yawDegrees: base.yawDegrees + extraYaw, flipHorizontal: flip),
                                     layout: layout,
                                     display: DisplayTransform(exposure: exposure, toneMapping: toneMapping),
                                     upscale: upscaling ? 2 : 1)
    }

    private var availableDownscales: [Int] { [1, 2, 4, 8, 16].filter { session.stack.width / $0 >= 512 } }

    var body: some View {
        NavigationStack {
            Form {
                formatSection
                Section("Contenu") {
                    Picker("Calques", selection: $activeLayerOnly) {
                        Text("Calques visibles").tag(false)
                        Text("Calque actif seul").tag(true)
                    }
                    Toggle("Papier blanc sous la peinture", isOn: $includePaper)
                        .disabled(kind == .jpeg)
                    Picker("Disposition", selection: $layout) {
                        ForEach(PanoramaLayout.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Section {
                    if layout == .equirectangular {
                        Toggle("Agrandir ×2 : \(session.stack.width * 2) × \(session.stack.height * 2)", isOn: $upscale)
                    }
                    if !upscaling {
                        ForEach(availableDownscales, id: \.self) { f in
                            Toggle(isOn: Binding(get: { downscales.contains(f) },
                                                 set: { on in if on { downscales.insert(f) } else if downscales.count > 1 { downscales.remove(f) } })) {
                                Text(resolutionText(f))
                            }
                        }
                    }
                } header: {
                    Text("Résolution")
                } footer: {
                    Text("Plusieurs résolutions cochées : un fichier par résolution, suffixé de sa largeur. « Agrandir » donne une image plus grande pour les logiciels qui l'exigent, sans détail en plus que la toile.")
                }
                Section("Orientation") {
                    Picker("Logiciel", selection: $preset) {
                        ForEach(OrientationPreset.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    LabeledContent("Décalage de lacet") {
                        Slider(value: $extraYaw, in: -180...180, step: 5)
                        Text("\(Int(extraYaw))°").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                    Toggle("Miroir horizontal", isOn: $flip)
                }
                if format.isDisplayReferred {
                    Section("Rendu écran (PNG, JPG)") {
                        LabeledContent("Exposition") {
                            Slider(value: $exposure, in: -6...6, step: 0.25)
                            Text(String(format: "%+.2f EV", exposure)).monospacedDigit().frame(width: 76, alignment: .trailing)
                        }
                        Picker("Courbe", selection: $toneMapping) {
                            ForEach(ToneMapping.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                    }
                }
                exportSection
            }
            .navigationTitle("Exporter la HDRI")
            .toolbar { Button("Fermer") { dismiss() }.disabled(session.isExporting) }
            .onAppear {
                exposure = session.exposure
                toneMapping = session.toneMapping
            }
        }
        .interactiveDismissDisabled(session.isExporting)
    }

    private var formatSection: some View {
        Section("Format") {
            Picker("Format", selection: $kind) {
                ForEach(ExportKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            switch kind {
            case .exr:
                Picker("Précision", selection: $pixelType) {
                    ForEach(EXRPixelType.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Compression", selection: $compression) {
                    ForEach(EXRCompression.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            case .hdr:
                EmptyView()
            case .png:
                Picker("Profondeur", selection: $pngDepth) {
                    Text("8 bits").tag(8)
                    Text("16 bits").tag(16)
                }
            case .jpeg:
                LabeledContent("Qualité") {
                    Slider(value: $jpegQuality, in: 0.3...1, step: 0.05)
                    Text("\(Int(jpegQuality * 100)) %").monospacedDigit().frame(width: 52, alignment: .trailing)
                }
            case .tiff:
                Picker("Précision", selection: $tiffDepth) {
                    Text("16 bits (half)").tag(16)
                    Text("32 bits (float)").tag(32)
                }
            }
            if supportsAlpha {
                Toggle("Canal alpha (RGBA)", isOn: $includeAlpha)
            }
        }
    }

    private var exportSection: some View {
        Section {
            if session.isExporting {
                ProgressView(value: session.exportProgress)
                Button("Annuler l'export", role: .destructive) { session.cancelExport() }
            } else {
                Button("Exporter", systemImage: "square.and.arrow.up") {
                    session.startExport(format: format, options: options, downscales: upscaling ? [1] : downscales.sorted(),
                                        activeLayerOnly: activeLayerOnly)
                }
            }
            if !session.lastExportURLs.isEmpty {
                ShareLink(items: session.lastExportURLs) {
                    Label("Partager ou enregistrer dans Fichiers", systemImage: "square.and.arrow.up.on.square")
                }
            }
            if let message = session.fileMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func resolutionText(_ downscale: Int) -> String {
        let width = session.stack.width / downscale
        if layout.isCubemap { return "Faces de \(width / 4) × \(width / 4)" }
        return "\(width) × \(session.stack.height / downscale)"
    }
}
