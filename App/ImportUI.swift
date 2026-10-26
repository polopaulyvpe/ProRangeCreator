import PhotosUI
import PRCore
import PRImaging
import PRStorage
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Les trois modes d'import de la section 15 du cahier des charges.
enum ImportMode: String, CaseIterable {
    case panorama
    case flat
    case cubemap

    var label: String {
        switch self {
        case .panorama: "Panorama équirectangulaire"
        case .flat: "Image plate face à la vue"
        case .cubemap: "Cubemap"
        }
    }
}

/// Image(s) décodée(s), en attente du choix du mode.
struct PendingImport: Identifiable, Sendable {
    let id = UUID()
    let name: String
    /// Une image, ou six faces dans l'ordre +X −X +Y −Y +Z −Z.
    let images: [ImportedImage]
    var cubemapLayout: CubemapSourceLayout? {
        images.count == 1 ? CubemapSourceLayout.detect(width: images[0].width, height: images[0].height) : nil
    }
    var isSixFaces: Bool { images.count == 6 }

    /// Mode proposé d'emblée : cubemap si six faces ou une croix, panorama si l'image est à peu près 2:1, sinon image plate.
    var suggestedMode: ImportMode {
        if isSixFaces || cubemapLayout != nil { return .cubemap }
        let ratio = Double(images[0].width) / Double(images[0].height)
        return abs(ratio - 2) < 0.15 ? .panorama : .flat
    }
}

/// Types acceptés par le sélecteur de fichiers.
let importableTypes: [UTType] = [.image, .png, .jpeg, .heic, .tiff, UTType("com.adobe.photoshop-image"),
                                 UTType("com.ilm.openexr-image"), UTType("public.radiance"),
                                 UTType(filenameExtension: "exr"), UTType(filenameExtension: "hdr")].compactMap { $0 }

/// Les fichiers sélectionnés peuvent venir d'un autre conteneur : l'accès est ouvert le temps de la lecture.
private struct SecurityScopedURL: @unchecked Sendable {
    let url: URL
}

extension CanvasSession {
    /// Ordre +X −X +Y −Y +Z −Z d'après les noms (px, posx, right…) ; ordre alphabétique sinon.
    nonisolated static func orderFaces(_ urls: [URL]) -> [URL] {
        let tokens: [[String]] = [["px", "posx", "right"], ["nx", "negx", "left"], ["py", "posy", "top", "up"],
                                  ["ny", "negy", "bottom", "down"], ["pz", "posz", "front"], ["nz", "negz", "back"]]
        let sorted = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var ordered = [URL?](repeating: nil, count: 6)
        for url in sorted {
            let words = url.deletingPathExtension().lastPathComponent.lowercased()
                .split(whereSeparator: { !$0.isLetter }).map(String.init)
            if let index = tokens.firstIndex(where: { set in words.contains(where: { set.contains($0) }) }), ordered[index] == nil {
                ordered[index] = url
            }
        }
        let found = ordered.compactMap { $0 }
        return found.count == 6 ? found : sorted
    }

    func loadImport(urls: [URL]) {
        guard !urls.isEmpty, !isDecodingImport else { return }
        let files = (urls.count == 6 ? Self.orderFaces(urls) : [urls[0]]).map(SecurityScopedURL.init)
        let name = urls[0].deletingPathExtension().lastPathComponent
        isDecodingImport = true
        Task.detached(priority: .userInitiated) {
            let result: Result<PendingImport, Error>
            do {
                var images: [ImportedImage] = []
                for file in files {
                    let access = file.url.startAccessingSecurityScopedResource()
                    defer { if access { file.url.stopAccessingSecurityScopedResource() } }
                    images.append(try ImageDecoder.decode(file.url))
                }
                result = .success(PendingImport(name: name, images: images))
            } catch {
                result = .failure(error)
            }
            await MainActor.run { self.finishDecoding(result) }
        }
    }

    func loadImport(data: Data, name: String) {
        guard !isDecodingImport else { return }
        isDecodingImport = true
        Task.detached(priority: .userInitiated) {
            let result = Result { try PendingImport(name: name, images: [ImageDecoder.decode(data: data)]) }
            await MainActor.run { self.finishDecoding(result) }
        }
    }

    /// Image du presse-papiers (PNG ou TIFF de préférence, sinon l'image UIKit convertie en PNG).
    func pasteImport() {
        let board = UIPasteboard.general
        let data = board.data(forPasteboardType: UTType.png.identifier)
            ?? board.data(forPasteboardType: UTType.tiff.identifier)
            ?? board.image?.pngData()
        guard let data else {
            fileMessage = "Le presse-papiers ne contient pas d'image"
            return
        }
        loadImport(data: data, name: "Presse-papiers")
    }

    private func finishDecoding(_ result: Result<PendingImport, Error>) {
        isDecodingImport = false
        switch result {
        case .success(let pending):
            pendingImport = pending
        case .failure(let error):
            fileMessage = "Import impossible : \(error)"
        }
    }

    /// Pose l'import sur un nouveau calque au-dessus du calque actif (une seule entrée d'historique).
    func applyImport(_ pending: PendingImport, mode: ImportMode, fit: PanoramaFit, yawDegrees: Double, angularWidthDegrees: Double) {
        strokeCancelled()
        guard stack.canAddLayer else {
            fileMessage = "Nombre maximal de calques atteint"
            return
        }
        let before = stack.items
        guard let item = stack.addLayer(above: activeID, name: "Import : \(pending.name.prefix(24))"), let layer = item.layer else { return }
        layer.beginOperation()
        switch mode {
        case .panorama:
            PanoramaImport.equirectangular(pending.images[0], into: layer, fit: fit, yawDegrees: yawDegrees)
        case .flat:
            let image = pending.images[0]
            let center = view.direction(atNDC: .zero, aspect: lastAspect) ?? [0, 0, -1]
            layer.placeImage(image.pixels, width: image.width, height: image.height, center: center,
                             angularWidth: angularWidthDegrees * .pi / 180)
        case .cubemap:
            if pending.isSixFaces {
                PanoramaImport.cubemap(pending.images, into: layer)
            } else if let layout = pending.cubemapLayout {
                PanoramaImport.cubemap(PanoramaImport.faces(from: pending.images[0], layout: layout), into: layer)
            }
        }
        let deltas = layer.endOperation()
        history.record(HistoryEntry(name: "Import", layerID: layer.id, deltas: deltas, structure: (before, stack.items)))
        refreshHistory()
        selectLayer(item.id)
        pendingImport = nil
    }
}

/// Entrées d'import du menu Fichier.
struct ImportMenuItems: View {
    @Bindable var session: CanvasSession
    @State private var photo: PhotosPickerItem?

    var body: some View {
        Button("Importer un fichier…", systemImage: "square.and.arrow.down.on.square") { session.showImporter = true }
        PhotosPicker(selection: $photo, matching: .images) {
            Label("Importer depuis Photos…", systemImage: "photo")
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    session.loadImport(data: data, name: "Photo")
                } else {
                    session.fileMessage = "Photo illisible"
                }
            }
        }
        Button("Coller une image", systemImage: "doc.on.clipboard") { session.pasteImport() }
    }
}

/// Choix du mode et de ses réglages, puis pose sur un nouveau calque.
struct ImportSheet: View {
    @Bindable var session: CanvasSession
    let pending: PendingImport
    @Environment(\.dismiss) private var dismiss
    @State private var mode: ImportMode = .panorama
    @State private var fit: PanoramaFit = .crop
    @State private var yaw = 0.0
    @State private var angularWidth = 60.0

    private var first: ImportedImage { pending.images[0] }
    private var isPanoramic: Bool { first.width == first.height * 2 }
    private var canCubemap: Bool { pending.isSixFaces || pending.cubemapLayout != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Image", value: pending.isSixFaces ? "6 faces de \(first.width) px" : "\(first.width) × \(first.height)")
                    Picker("Mode", selection: $mode) {
                        ForEach(ImportMode.allCases, id: \.self) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                switch mode {
                case .panorama:
                    Section("Panorama") {
                        if !isPanoramic {
                            Picker("Pas au format 2:1", selection: $fit) {
                                ForEach(PanoramaFit.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                        }
                        LabeledContent("Rotation") {
                            Slider(value: $yaw, in: -180...180, step: 5)
                            Text("\(Int(yaw))°").monospacedDigit().frame(width: 48, alignment: .trailing)
                        }
                        Text("Rééchantillonné à \(session.stack.width) × \(session.stack.height).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .flat:
                    Section("Image plate") {
                        LabeledContent("Largeur angulaire") {
                            Slider(value: $angularWidth, in: 5...150, step: 1)
                            Text("\(Int(angularWidth))°").monospacedDigit().frame(width: 48, alignment: .trailing)
                        }
                        Text("Posée face au centre de la vue, sans distorsion ; transformable ensuite avec la sélection.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .cubemap:
                    Section("Cubemap") {
                        if pending.isSixFaces {
                            Text("Six fichiers, ordre déduit des noms (px/nx…, posx/negx…, right/left…).")
                        } else if let layout = pending.cubemapLayout {
                            Text("Disposition détectée : \(layout.label).")
                        } else {
                            Text("Proportions non reconnues : il faut une croix (4:3 ou 3:4), une bande (6:1 ou 1:6) ou six fichiers.")
                                .foregroundStyle(.red)
                        }
                        Text("Convention OpenGL (+Y en haut), comme l'export cubemap.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Importer sur un nouveau calque", systemImage: "square.and.arrow.down") {
                        session.applyImport(pending, mode: mode, fit: fit, yawDegrees: yaw, angularWidthDegrees: angularWidth)
                        dismiss()
                    }
                    .disabled(mode == .cubemap && !canCubemap)
                }
            }
            .navigationTitle("Importer")
            .toolbar { Button("Annuler") { session.pendingImport = nil } }
            .onAppear { mode = pending.suggestedMode }
        }
    }
}
