import CoreGraphics
import PRCore
import SwiftUI

/// Aperçu d'un trait (blanc sur transparent) : la forme ou le dab rond tamponné le long d'une courbe, effilé aux bouts.
@MainActor
enum StrokePreview {
    private static var cache: [String: CGImage] = [:]
    static let width = 280
    static let height = 52

    static func image(id: String, settings: BrushSettings) -> CGImage? {
        if let cached = cache[id] { return cached }
        let image = render(settings)
        cache[id] = image
        return image
    }

    /// Même calcul que la toile (`FlatBrushPainter`), rayon de 15 pixels (22 pour un tampon).
    static func render(_ s: BrushSettings) -> CGImage? {
        FlatBrushPainter.preview(s, width: width, height: height, radiusPixels: s.spacing >= 10 ? 22 : 15)
    }
}

/// Une entrée de la bibliothèque (intégrée, de base ou enregistrée).
struct BrushEntry: Identifiable {
    let id: String
    let name: String
    let settings: BrushSettings
}

/// Bibliothèque de pinceaux : catégories à gauche, aperçus de traits à droite (même organisation que Procreate).
struct BrushPanel: View {
    @Bindable var session: CanvasSession
    @State private var category = "Base"
    @State private var saved: [LibraryBrush] = []

    private var categories: [String] { ["Base"] + BuiltInBrushes.categories + ["Mes pinceaux"] }

    private var entries: [BrushEntry] {
        switch category {
        case "Base":
            [BrushEntry(id: "base/rond", name: "Rond dur", settings: BrushSettings(radiusDegrees: 2, hardness: 0.9, spacing: 0.12)),
             BrushEntry(id: "base/doux", name: "Aérographe doux", settings: BrushSettings(radiusDegrees: 6, opacity: 0.4, hardness: 0, spacing: 0.1,
                                                                                          pressureAffectsSize: false, pressureAffectsOpacity: true)),
             BrushEntry(id: "base/encre", name: "Encre", settings: BrushSettings(radiusDegrees: 0.8, hardness: 1, spacing: 0.08, minimumSize: 0.05)),
             BrushEntry(id: "base/gomme", name: "Gomme douce", settings: BrushSettings.defaultEraser)]
        case "Mes pinceaux":
            saved.map { BrushEntry(id: "mes/\($0.url.lastPathComponent)", name: $0.preset.name, settings: $0.preset.settings) }
        default:
            BuiltInBrushes.all.filter { $0.category == category }.map { BrushEntry(id: $0.id, name: $0.name, settings: $0.settings) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Bibliothèque").font(.system(size: 28, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Button {
                    session.showBrushes = false
                    session.showBrushLibrary = true
                } label: {
                    Image(systemName: "plus").font(.system(size: 26, weight: .regular)).foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
            HStack(alignment: .top, spacing: 14) {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(categories, id: \.self) { name in
                            Button { category = name } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: symbol(name)).frame(width: 22)
                                    Text(name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 14)
                                .foregroundStyle(.white.opacity(0.85))
                                .background(RoundedRectangle(cornerRadius: 12).fill(category == name ? Color.accentColor : Color(white: 0.27)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(width: 180)
                ScrollView {
                    VStack(spacing: 6) {
                        if entries.isEmpty {
                            Text("Aucun pinceau enregistré. « + » pour en importer ou enregistrer le pinceau actuel.")
                                .font(.callout).foregroundStyle(.white.opacity(0.6)).padding()
                        }
                        ForEach(entries) { entry in
                            Button {
                                session.settings = entry.settings
                                session.showToast(entry.name)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.name).font(.system(size: 16, weight: .semibold))
                                    if let image = StrokePreview.image(id: entry.id, settings: entry.settings) {
                                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                                    }
                                }
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 12).fill(isCurrent(entry) ? Color.accentColor : .clear))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Modifier dans l'Atelier", systemImage: "slider.horizontal.3") {
                                    session.settings = entry.settings
                                    session.showBrushes = false
                                    session.showBrushStudio = true
                                }
                            }
                        }
                    }
                }
            }
            HStack {
                Button {
                    session.showBrushes = false
                    session.showBrushStudio = true
                } label: {
                    Label("Atelier de pinceaux…", systemImage: "slider.horizontal.3")
                        .font(.callout)
                }
                Spacer()
                Button {
                    session.showBrushes = false
                    session.showBrushLibrary = true
                } label: {
                    Label("Importer, enregistrer…", systemImage: "square.and.arrow.down")
                        .font(.callout)
                }
            }
        }
        .padding(20)
        .frame(width: 540, height: 640)
        .background(Color(white: 0.2))
        .environment(\.colorScheme, .dark)
        .presentationCompactAdaptation(.popover)
        .onAppear { saved = session.listBrushes() }
    }

    private func isCurrent(_ entry: BrushEntry) -> Bool {
        let s = session.settings
        return s.shape == entry.settings.shape && s.grain == entry.settings.grain
            && s.radiusDegrees == entry.settings.radiusDegrees && s.hardness == entry.settings.hardness
    }

    private func symbol(_ category: String) -> String {
        switch category {
        case "Base": "paintbrush.pointed"
        case "Nuages": "cloud"
        case "Ciel nocturne": "moon.stars"
        case "Atmosphère": "sun.haze"
        case "Végétation": "leaf"
        case "Tampons": "seal"
        default: "folder"
        }
    }
}
