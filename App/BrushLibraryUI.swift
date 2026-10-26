import PRCore
import PRImaging
import SwiftUI
import UniformTypeIdentifiers

/// Fichier de la bibliothèque : un `.prbrush` dans Documents/Pinceaux.
struct LibraryBrush: Identifiable {
    let url: URL
    let preset: BrushPreset
    var id: URL { url }
}

/// Ce que le sélecteur de fichiers doit ouvrir.
enum BrushFileRequest {
    case brushes
    case shape
    case grain
}

extension CanvasSession {
    static var brushesDirectory: URL {
        let url = URL.documentsDirectory.appendingPathComponent("Pinceaux", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func listBrushes() -> [LibraryBrush] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.brushesDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "prbrush" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url), let preset = try? NativeBrushFile.preset(from: data) else { return nil }
                return LibraryBrush(url: url, preset: preset)
            }
            .sorted { $0.preset.name.localizedStandardCompare($1.preset.name) == .orderedAscending }
    }

    /// Enregistre un pinceau dans la bibliothèque (un nom déjà pris est numéroté).
    @discardableResult
    func saveBrush(_ preset: BrushPreset) -> URL? {
        let base = preset.name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        var url = Self.brushesDirectory.appendingPathComponent("\(base).prbrush")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = Self.brushesDirectory.appendingPathComponent("\(base) \(n).prbrush")
            n += 1
        }
        do {
            try NativeBrushFile.data(preset).write(to: url)
            return url
        } catch {
            fileMessage = "Pinceau non enregistré : \(error)"
            return nil
        }
    }

    /// .brush, .brushset (Procreate) ou .prbrush : ajoutés à la bibliothèque ; renvoie les pinceaux lus pour le compte rendu.
    func importBrushFiles(_ urls: [URL]) -> [BrushPreset] {
        var imported: [BrushPreset] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                if url.pathExtension.lowercased() == "prbrush" {
                    imported.append(try NativeBrushFile.preset(from: Data(contentsOf: url)))
                } else {
                    imported += try ProcreateBrushImport.read(url)
                }
            } catch {
                fileMessage = "\(url.lastPathComponent) illisible : \(error)"
            }
        }
        for preset in imported { saveBrush(preset) }
        return imported
    }

    /// Image (PNG ou autre) comme forme ou grain du pinceau courant.
    func importTexture(_ url: URL, asGrain: Bool, invert: Bool) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let image = try ImageDecoder.decode(url)
            let texture = BrushTextureImport.texture(from: image, name: url.deletingPathExtension().lastPathComponent, invert: invert)
            if asGrain { settings.grain = texture } else { settings.shape = texture }
        } catch {
            fileMessage = "Image illisible : \(error)"
        }
    }
}

/// Bibliothèque de pinceaux et réglages de forme et de grain du pinceau (ou de la gomme) courant.
struct BrushLibrarySheet: View {
    @Bindable var session: CanvasSession
    @Environment(\.dismiss) private var dismiss
    @State private var brushes: [LibraryBrush] = []
    @State private var request: BrushFileRequest?
    @State private var showPicker = false
    @State private var invertTexture = false
    @State private var newName = "Mon pinceau"
    @State private var report: [BrushPreset] = []

    private var pickerTypes: [UTType] {
        switch request {
        case .brushes:
            ["brush", "brushset", "prbrush"].compactMap { UTType(filenameExtension: $0) } + [.zip, .data]
        default:
            [.image]
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Forme") {
                    LabeledContent("Forme", value: session.settings.shape?.name ?? "Ronde (dureté)")
                    HStack {
                        Button("Importer une image…") { open(.shape) }
                        if session.settings.shape != nil {
                            Spacer()
                            Button("Retirer", role: .destructive) { session.settings.shape = nil }
                        }
                    }
                    if session.settings.shape != nil {
                        LabeledContent("Rotation") {
                            Slider(value: $session.settings.shapeRotationDegrees, in: -180...180, step: 1)
                            Text("\(Int(session.settings.shapeRotationDegrees))°").monospacedDigit().frame(width: 48, alignment: .trailing)
                        }
                        Toggle("Suit la direction du trait", isOn: $session.settings.followStroke)
                    }
                }
                Section("Grain") {
                    LabeledContent("Grain", value: session.settings.grain?.name ?? "Aucun")
                    HStack {
                        Button("Importer une image…") { open(.grain) }
                        if session.settings.grain != nil {
                            Spacer()
                            Button("Retirer", role: .destructive) { session.settings.grain = nil }
                        }
                    }
                    if session.settings.grain != nil {
                        LabeledContent("Échelle") {
                            Slider(value: $session.settings.grainScaleDegrees, in: 0.2...30)
                            Text(String(format: "%.1f°", session.settings.grainScaleDegrees)).monospacedDigit().frame(width: 52, alignment: .trailing)
                        }
                        LabeledContent("Profondeur") {
                            Slider(value: $session.settings.grainDepth, in: 0...1)
                            Text("\(Int(session.settings.grainDepth * 100)) %").monospacedDigit().frame(width: 52, alignment: .trailing)
                        }
                    }
                    Toggle("Inverser l'image importée (forme noire sur blanc)", isOn: $invertTexture)
                }
                ForEach(BuiltInBrushes.categories, id: \.self) { category in
                    Section(category) {
                        ForEach(BuiltInBrushes.all.filter { $0.category == category }) { builtIn in
                            Button {
                                session.settings = builtIn.settings
                                dismiss()
                            } label: {
                                HStack {
                                    if let shape = builtIn.settings.shape { TexturePreview(texture: shape).frame(width: 36, height: 36) }
                                    VStack(alignment: .leading) {
                                        Text(builtIn.name)
                                        Text(summary(builtIn.settings)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                Section {
                    ForEach(brushes) { brush in
                        Button {
                            session.settings = brush.preset.settings
                            dismiss()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(brush.preset.name)
                                Text(summary(brush.preset.settings)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { try? FileManager.default.removeItem(at: brushes[i].url) }
                        brushes = session.listBrushes()
                    }
                    HStack {
                        TextField("Nom", text: $newName)
                        Button("Enregistrer le pinceau actuel") {
                            session.saveBrush(BrushPreset(name: newName, settings: session.settings))
                            brushes = session.listBrushes()
                        }
                    }
                    Button("Importer .brush, .brushset ou .prbrush…", systemImage: "square.and.arrow.down") { open(.brushes) }
                } header: {
                    Text("Mes pinceaux")
                } footer: {
                    Text("Import Procreate au mieux : forme, grain, taille, opacité, espacement, pression, rotation et grain sont repris ; le reste est listé comme ignoré.")
                }
                if !report.isEmpty {
                    Section("Dernier import") {
                        ForEach(report) { preset in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preset.name).font(.headline)
                                if !preset.mapped.isEmpty {
                                    Text("Repris : " + preset.mapped.joined(separator: " · ")).font(.caption)
                                }
                                if !preset.ignored.isEmpty {
                                    Text("Ignorés : " + preset.ignored.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if let message = session.fileMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(session.tool == .eraser ? "Gomme" : "Pinceau")
            .toolbar { Button("Fermer") { dismiss() } }
            .onAppear { brushes = session.listBrushes() }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: pickerTypes, allowsMultipleSelection: request == .brushes) { result in
                guard case .success(let urls) = result, let request else { return }
                switch request {
                case .brushes:
                    report = session.importBrushFiles(urls)
                    brushes = session.listBrushes()
                case .shape, .grain:
                    if let url = urls.first { session.importTexture(url, asGrain: request == .grain, invert: invertTexture) }
                }
            }
        }
    }

    private func open(_ kind: BrushFileRequest) {
        request = kind
        showPicker = true
    }

    private func summary(_ s: BrushSettings) -> String {
        var parts = [String(format: "%.1f°", s.radiusDegrees), "opacité \(Int(s.opacity * 100)) %"]
        if s.shape != nil { parts.append("forme") }
        if s.grain != nil { parts.append("grain") }
        return parts.joined(separator: " · ")
    }
}

/// Vignette d'une forme (blanc sur fond sombre), réduite à 64 × 64.
struct TexturePreview: View {
    let texture: BrushTexture

    var body: some View {
        if let image = Self.image(texture) {
            Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                .background(Color.black).clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    static func image(_ texture: BrushTexture) -> CGImage? {
        let side = 64
        var bytes = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let v = texture.sample((Double(x) + 0.5) / Double(side), (Double(y) + 0.5) / Double(side), wrap: false)
                bytes[y * side + x] = UInt8(min(1, max(0, v)) * 255 + 0.5)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
