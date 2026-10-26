import Metal
import PRCore
import PREngine
import PRImaging
import SwiftUI

/// Les captures du timelapse vivent dans un dossier de travail, copié dans `timelapse/` du projet à l'enregistrement.
extension CanvasSession {
    static var timelapseWorkingDirectory: URL {
        URL.cachesDirectory.appendingPathComponent("Timelapse/courant", isDirectory: true)
    }

    /// Enregistreur (créé à la première capture).
    var timelapseRecorder: TimelapseRecorder? {
        if let recorder = timelapse { return recorder }
        timelapse = try? TimelapseRecorder(directory: Self.timelapseWorkingDirectory)
        return timelapse
    }

    /// Capture de la vue dépliée entière (1024 × 512, exposition et courbe de l'écran), après une opération.
    func captureTimelapseFrame(canvas: StackCanvas, renderer: PanoramaRenderer) {
        guard timelapseEnabled, let recorder = timelapseRecorder, let layers = canvas.panoramaLayers() else { return }
        let width = 1024, height = 512
        var state = ViewState()
        state.mode = .unfolded
        state.morph = 1
        var uniforms = ViewUniforms(state.parameters(aspect: 2), viewportHeight: height, textureHeight: layers.below.height,
                                    exposure: exposure, toneMapping: toneMapping)
        canvas.configure(&uniforms)
        guard let halves = try? renderer.renderOffscreen(layers: layers, width: width, height: height, uniforms: uniforms) else { return }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            rgba[i * 4] = ColorTransfer.encode8(Float(halves[i * 4]))
            rgba[i * 4 + 1] = ColorTransfer.encode8(Float(halves[i * 4 + 1]))
            rgba[i * 4 + 2] = ColorTransfer.encode8(Float(halves[i * 4 + 2]))
        }
        recorder.append(rgba: rgba, width: width, height: height)
        timelapseFrames = recorder.frameCount
    }

    func startTimelapseExport(view: TimelapseView, width: Int, height: Int) {
        guard !isExporting, let recorder = timelapseRecorder else { return }
        let frames = recorder.frameURLs
        guard !frames.isEmpty else {
            fileMessage = "Aucune image de timelapse pour l'instant"
            return
        }
        let url = Self.exportsDirectory.appendingPathComponent("\(projectName)-timelapse.mp4")
        let cancel = CancelFlag()
        exportCancel = cancel
        isExporting = true
        exportProgress = 0
        lastExportURLs = []
        Task.detached(priority: .userInitiated) {
            let result = Result {
                try TimelapseExporter.export(frames: frames, to: url, width: width, height: height, view: view) { progress in
                    Task { @MainActor in self.exportProgress = progress }
                    return !cancel.isCancelled
                }
                return url
            }
            await MainActor.run {
                self.isExporting = false
                self.exportCancel = nil
                switch result {
                case .success(let url):
                    self.lastExportURLs = [url]
                    self.fileMessage = "Timelapse exporté : \(url.lastPathComponent)"
                case .failure(let error):
                    self.fileMessage = "Échec du timelapse : \(error)"
                }
            }
        }
    }
}

struct TimelapseSheet: View {
    @Bindable var session: CanvasSession
    @Environment(\.dismiss) private var dismiss
    @State private var sphere = false
    @State private var fov = 90.0
    @State private var turns = 1.0
    @State private var large = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Enregistrer le timelapse", isOn: $session.timelapseEnabled)
                    LabeledContent("Images enregistrées", value: "\(session.timelapseFrames)")
                } footer: {
                    Text("Une image de la vue dépliée après chaque opération, gardée avec le projet.")
                }
                Section("Vidéo H.265") {
                    Picker("Vue", selection: $sphere) {
                        Text("Dépliée").tag(false)
                        Text("Sphère qui tourne").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if sphere {
                        LabeledContent("Champ de vision") {
                            Slider(value: $fov, in: 40...120, step: 5)
                            Text("\(Int(fov))°").monospacedDigit().frame(width: 48, alignment: .trailing)
                        }
                        Stepper("Tours : \(Int(turns))", value: $turns, in: 0...4)
                    }
                    Toggle(sphere ? "1920 × 1080 (sinon 1280 × 720)" : "2048 × 1024 (sinon 1024 × 512)", isOn: $large)
                }
                Section {
                    if session.isExporting {
                        ProgressView(value: session.exportProgress)
                        Button("Annuler", role: .destructive) { session.cancelExport() }
                    } else {
                        Button("Exporter la vidéo", systemImage: "film") {
                            let size = sphere ? (large ? (1920, 1080) : (1280, 720)) : (large ? (2048, 1024) : (1024, 512))
                            session.startTimelapseExport(view: sphere ? .sphere(fovDegrees: fov, turns: turns) : .unfolded,
                                                         width: size.0, height: size.1)
                        }
                        .disabled(session.timelapseFrames == 0)
                    }
                    if !session.lastExportURLs.isEmpty {
                        ShareLink(items: session.lastExportURLs) { Label("Partager", systemImage: "square.and.arrow.up") }
                    }
                    if let message = session.fileMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Timelapse")
            .toolbar { Button("Fermer") { dismiss() }.disabled(session.isExporting) }
            .onAppear { session.timelapseFrames = session.timelapseRecorder?.frameCount ?? 0 }
        }
        .interactiveDismissDisabled(session.isExporting)
    }
}
