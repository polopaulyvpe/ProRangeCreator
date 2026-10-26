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

    private static func render(_ s: BrushSettings) -> CGImage? {
        let w = width, h = height
        var alpha = [Float](repeating: 0, count: w * h)
        let maxRadius: Double = s.spacing >= 10 ? 22 : 15
        let isStamp = s.spacing >= 10
        var x: Double = isStamp ? Double(w) / 2 : 14
        var previous: (Double, Double)?
        var random = StrokeRandom(seed: 7)
        while x <= Double(w) - 14 {
            let r = s.hasJitter ? random.dab() : .none
            let t = isStamp ? 0.5 : (x - 14) / Double(w - 28)
            var y = Double(h) / 2 + sin(t * 2 * .pi) * Double(h) * 0.18
            let pressure = isStamp ? 1 : 0.35 + 0.65 * sin(t * .pi)
            let radius = maxRadius * (s.pressureAffectsSize ? pressure : 1) * (1 - s.sizeJitter * r.size)
            let opacity = Float(s.opacity * (s.pressureAffectsOpacity ? pressure : 1) * (1 - s.opacityJitter * r.opacity))
            y += s.scatter * 2 * radius * (r.scatter * 2 - 1)
            var angle = s.shapeRotationDegrees * .pi / 180
            if s.followStroke, let p = previous { angle += atan2(-(y - p.1), x - p.0) }
            angle += s.rotationJitter * (r.rotation * 2 - 1)
            stamp(&alpha, w: w, h: h, cx: x, cy: y, radius: max(1.5, radius), opacity: opacity, angle: angle,
                  flip: s.randomFlip && r.flip, settings: s)
            previous = (x, y)
            if isStamp { break }
            x += max(0.8, s.spacing(radius: radius, random: random.next()))
        }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let a = UInt8(min(1, alpha[i]) * 255 + 0.5)
            bytes[i * 4] = a
            bytes[i * 4 + 1] = a
            bytes[i * 4 + 2] = a
            bytes[i * 4 + 3] = a
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func stamp(_ alpha: inout [Float], w: Int, h: Int, cx: Double, cy: Double, radius: Double, opacity: Float,
                              angle: Double, flip: Bool, settings s: BrushSettings) {
        let reach = s.shape != nil ? radius * 1.42 : radius
        let c = cos(angle), sn = sin(angle)
        let y0 = max(0, Int(cy - reach)), y1 = min(h - 1, Int(cy + reach))
        let x0 = max(0, Int(cx - reach)), x1 = min(w - 1, Int(cx + reach))
        guard y0 <= y1, x0 <= x1 else { return }
        for py in y0...y1 {
            for px in x0...x1 {
                let dx = (Double(px) + 0.5 - cx) / radius
                let dy = -(Double(py) + 0.5 - cy) / radius
                var a: Float
                if let shape = s.shape {
                    let rx = dx * c + dy * sn, qy = -dx * sn + dy * c
                    let qx = flip ? -rx : rx
                    guard abs(qx) <= 1, abs(qy) <= 1 else { continue }
                    a = shape.sample((qx + 1) / 2, (1 - qy) / 2, wrap: false)
                } else {
                    a = Float(SphericalRasterizer.coverage(distance: (dx * dx + dy * dy).squareRoot(), radius: 1,
                                                           hardness: s.hardness, pixelSize: 1 / radius))
                }
                if let grain = s.grain {
                    let g = grain.sample(Double(px) / 48, Double(py) / 48, wrap: true)
                    a *= 1 - Float(s.grainDepth) * (1 - g)
                }
                guard a > 0 else { continue }
                let i = py * w + px
                alpha[i] += a * opacity * (1 - alpha[i])
            }
        }
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
                        }
                    }
                }
            }
            Button {
                session.showBrushes = false
                session.showBrushLibrary = true
            } label: {
                Label("Forme, grain et réglages du pinceau…", systemImage: "slider.horizontal.3")
                    .font(.callout)
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
