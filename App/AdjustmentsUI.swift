import PRCore
import PREngine
import PRStorage
import simd
import SwiftUI

/// Les entrées du menu Ajustements.
enum FilterKind: String, CaseIterable, Identifiable {
    case hueSaturation, colorBalance, curves, gradientMap, recolor
    case gaussianBlur, motionBlur, noise, sharpen, bloom, chromatic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hueSaturation: "Teinte, saturation, luminosité"
        case .colorBalance: "Balance des couleurs"
        case .curves: "Courbes"
        case .gradientMap: "Carte de dégradé"
        case .recolor: "Recoloration"
        case .gaussianBlur: "Flou gaussien"
        case .motionBlur: "Flou de mouvement"
        case .noise: "Bruit"
        case .sharpen: "Netteté"
        case .bloom: "Bloom"
        case .chromatic: "Aberration chromatique"
        }
    }

    var isColorAdjustment: Bool {
        switch self {
        case .hueSaturation, .colorBalance, .curves, .gradientMap, .recolor: true
        default: false
        }
    }
}

enum ToneRange: String, CaseIterable {
    case shadows, midtones, highlights

    var label: String {
        switch self {
        case .shadows: "Ombres"
        case .midtones: "Tons moyens"
        case .highlights: "Hautes lumières"
        }
    }
}

/// Réglages de tous les filtres (gardés d'une ouverture à l'autre).
struct FilterSettings {
    var hue = 0.0, saturation = 0.0, brightness = 0.0
    var balanceRange: ToneRange = .midtones
    var shadows = SIMD3<Double>.zero, midtones = SIMD3<Double>.zero, highlights = SIMD3<Double>.zero
    /// Valeurs de sortie de la courbe aux entrées 0, ¼, ½, ¾ et 1 (× maximum).
    var curve: [Double] = [0, 0.25, 0.5, 0.75, 1]
    var curveHDR = false
    var recolorTo = 0.5, recolorTolerance = 0.08
    var blurDegrees = 1.0
    var motionDegrees = 5.0, motionAngle = 0.0
    var noiseAmount = 0.08, noiseGrain = 1.0, noiseMono = true
    var sharpenDegrees = 0.5, sharpenAmount = 1.0
    var bloomThreshold = 1.0, bloomDegrees = 3.0, bloomIntensity = 0.6
    var chromaticStrength = 0.01
}

extension CanvasSession {
    func openFilter(_ kind: FilterKind) {
        strokeCancelled()
        cancelTransform()
        cancelDistort()
        if activeFilter != nil { _ = canvas?.endFilter(apply: false) }
        activeFilter = kind
        canvas?.beginFilter()
        filterPreviewIsLive = canvas?.filterPreviewIsLive ?? false
        updateFilterPreview()
    }

    /// Opération correspondant aux réglages courants.
    func filterOperation(_ kind: FilterKind) -> FilterOperation {
        let s = filterSettings
        let pixelAngle = Double.pi / Double(stack.height)
        switch kind {
        case .hueSaturation:
            return .adjustment(.hueSaturation(hue: s.hue, saturation: s.saturation, brightness: s.brightness))
        case .colorBalance:
            return .adjustment(.colorBalance(shadows: s.shadows, midtones: s.midtones, highlights: s.highlights))
        case .curves:
            let top = s.curveHDR ? 4.0 : 1.0
            let points = s.curve.enumerated().map { SIMD2<Double>(Double($0.offset) / 4 * top, $0.element * top) }
            return .adjustment(.curves(ToneCurve(points: points, maxInput: top)))
        case .gradientMap:
            return .adjustment(.gradientMap(dark: .zero, light: color))
        case .recolor:
            return .adjustment(.recolor(from: HSBColor(rgb: color).hue, to: s.recolorTo, tolerance: s.recolorTolerance))
        case .gaussianBlur:
            return .filter(.gaussianBlur(radius: s.blurDegrees * .pi / 180))
        case .motionBlur:
            return .filter(.motionBlur(length: s.motionDegrees * .pi / 180, angle: s.motionAngle * .pi / 180))
        case .noise:
            return .filter(.noise(amount: s.noiseAmount, cell: pixelAngle * s.noiseGrain, seed: 7, monochrome: s.noiseMono))
        case .sharpen:
            return .filter(.sharpen(radius: s.sharpenDegrees * .pi / 180, amount: s.sharpenAmount))
        case .bloom:
            return .filter(.bloom(threshold: s.bloomThreshold, radius: s.bloomDegrees * .pi / 180, intensity: s.bloomIntensity))
        case .chromatic:
            let center = view.direction(atNDC: .zero, aspect: lastAspect) ?? [0, 0, -1]
            return .filter(.chromaticAberration(center: center, strength: s.chromaticStrength))
        }
    }

    func updateFilterPreview() {
        guard let kind = activeFilter else { return }
        canvas?.previewFilter(filterOperation(kind))
    }

    func applyFilter() {
        guard let kind = activeFilter else { return }
        canvas?.previewFilter(filterOperation(kind))
        if let result = canvas?.endFilter(apply: true), !result.deltas.isEmpty {
            history.record(HistoryEntry(name: kind.label, layerID: result.layerID, deltas: result.deltas))
            refreshHistory()
        }
        activeFilter = nil
    }

    func cancelFilter() {
        _ = canvas?.endFilter(apply: false)
        activeFilter = nil
    }

    /// Calcule l'effet puis passe au pinceau d'effet : chaque trait révèle le résultat là où on peint.
    func paintFilter() {
        guard let kind = activeFilter else { return }
        canvas?.previewFilter(filterOperation(kind))
        let effect = canvas?.filterResultLayer()
        _ = canvas?.endFilter(apply: false)
        activeFilter = nil
        guard let effect else { return }
        cloneSampler = LayerSampler(effect)
        cloneRotation = matrix_identity_double3x3
        tool = .effect
        fileMessage = "Pinceau d'effet : \(kind.label)"
    }
}

struct AdjustmentsMenu: View {
    @Bindable var session: CanvasSession

    var body: some View {
        Menu {
            Section("Couleur") {
                ForEach(FilterKind.allCases.filter(\.isColorAdjustment)) { kind in
                    Button(kind.label) { session.openFilter(kind) }
                }
            }
            Section("Filtres") {
                ForEach(FilterKind.allCases.filter { !$0.isColorAdjustment }) { kind in
                    Button(kind.label) { session.openFilter(kind) }
                }
            }
        } label: {
            Label("Ajustements", systemImage: "wand.and.rays")
        }
        .fixedSize()
    }
}

/// Réglages du filtre ouvert, aperçu mis à jour à chaque changement.
struct FilterPanel: View {
    @Bindable var session: CanvasSession

    var body: some View {
        if let kind = session.activeFilter {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(kind.label).font(.headline)
                    Spacer()
                    if !session.filterPreviewIsLive {
                        Text("Aperçu à l'application (sélection, masque ou calque dans un groupe)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                controls(kind)
                HStack {
                    Button("Annuler") { session.cancelFilter() }
                    Spacer()
                    Button("Peindre l'effet") { session.paintFilter() }
                    Button("Appliquer") { session.applyFilter() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .font(.callout)
            .padding(12)
            .frame(width: 420)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .onChange(of: session.filterSettings.revision) { session.updateFilterPreview() }
        }
    }

    @ViewBuilder
    private func controls(_ kind: FilterKind) -> some View {
        switch kind {
        case .hueSaturation:
            slider("Teinte", \.hue, -0.5...0.5, percent: false, unit: "tour")
            slider("Saturation", \.saturation, -1...1)
            slider("Luminosité", \.brightness, -1...1)
        case .colorBalance:
            Picker("Plage", selection: $session.filterSettings.balanceRange) {
                ForEach(ToneRange.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            let range = balanceKeyPath
            slider("Cyan ↔ Rouge", range.appending(path: \.x), -1...1)
            slider("Magenta ↔ Vert", range.appending(path: \.y), -1...1)
            slider("Jaune ↔ Bleu", range.appending(path: \.z), -1...1)
        case .curves:
            CurveEditor(values: $session.filterSettings.curve)
                .frame(height: 140)
            Toggle("Domaine HDR (0 à 4)", isOn: $session.filterSettings.curveHDR)
        case .gradientMap:
            Text("Du noir (ombres) à la couleur courante (lumières).").font(.caption).foregroundStyle(.secondary)
        case .recolor:
            Text("Change la teinte de la couleur courante dans l'image.").font(.caption).foregroundStyle(.secondary)
            slider("Nouvelle teinte", \.recolorTo, 0...1, percent: false, unit: "tour")
            slider("Tolérance", \.recolorTolerance, 0.01...0.3)
        case .gaussianBlur:
            slider("Rayon", \.blurDegrees, 0.05...20, percent: false, unit: "°")
        case .motionBlur:
            slider("Longueur", \.motionDegrees, 0.2...40, percent: false, unit: "°")
            slider("Direction", \.motionAngle, -180...180, percent: false, unit: "°")
        case .noise:
            slider("Quantité", \.noiseAmount, 0...0.5)
            slider("Taille du grain", \.noiseGrain, 1...8, percent: false, unit: "px")
            Toggle("Monochrome", isOn: $session.filterSettings.noiseMono)
        case .sharpen:
            slider("Rayon", \.sharpenDegrees, 0.05...5, percent: false, unit: "°")
            slider("Force", \.sharpenAmount, 0...3)
        case .bloom:
            slider("Seuil (linéaire)", \.bloomThreshold, 0...4, percent: false, unit: "")
            slider("Rayon", \.bloomDegrees, 0.2...20, percent: false, unit: "°")
            slider("Intensité", \.bloomIntensity, 0...2)
        case .chromatic:
            slider("Écart", \.chromaticStrength, 0...0.05)
            Text("Centré sur la direction regardée à l'ouverture.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var balanceKeyPath: WritableKeyPath<FilterSettings, SIMD3<Double>> {
        switch session.filterSettings.balanceRange {
        case .shadows: \.shadows
        case .midtones: \.midtones
        case .highlights: \.highlights
        }
    }

    private func slider(_ title: String, _ keyPath: WritableKeyPath<FilterSettings, Double>, _ range: ClosedRange<Double>,
                        percent: Bool = true, unit: String = "") -> some View {
        let value = session.filterSettings[keyPath: keyPath]
        let shown = percent ? "\(Int(value * 100)) %" : "\(value.formatted(.number.precision(.fractionLength(0...2)))) \(unit)"
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(title) \(shown)").font(.caption).monospacedDigit()
            Slider(value: Binding(get: { session.filterSettings[keyPath: keyPath] },
                                  set: { session.filterSettings[keyPath: keyPath] = $0 }), in: range)
        }
    }
}

extension FilterSettings {
    /// Change à chaque modification : déclenche le recalcul de l'aperçu.
    var revision: Int {
        var hasher = Hasher()
        for v in [hue, saturation, brightness, recolorTo, recolorTolerance, blurDegrees, motionDegrees, motionAngle,
                  noiseAmount, noiseGrain, sharpenDegrees, sharpenAmount, bloomThreshold, bloomDegrees, bloomIntensity,
                  chromaticStrength] + curve {
            hasher.combine(v)
        }
        for v in [shadows, midtones, highlights] { hasher.combine(v.x); hasher.combine(v.y); hasher.combine(v.z) }
        hasher.combine(curveHDR)
        hasher.combine(noiseMono)
        return hasher.finalize()
    }
}

/// Courbe à cinq points : on tire verticalement chaque point (entrées fixes 0, ¼, ½, ¾, 1).
struct CurveEditor: View {
    @Binding var values: [Double]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let points = values.enumerated().map { CGPoint(x: CGFloat($0.offset) / 4 * w, y: (1 - CGFloat($0.element)) * h) }
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h))
                    path.addLine(to: CGPoint(x: w, y: 0))
                }
                .stroke(.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                Path { path in path.addLines(points) }
                    .stroke(.tint, lineWidth: 2)
                ForEach(points.indices, id: \.self) { i in
                    Circle().fill(.tint).frame(width: 14, height: 14).position(points[i])
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let i = min(4, max(0, Int((drag.location.x / w * 4).rounded())))
                values[i] = min(1.5, max(0, 1 - Double(drag.location.y / h)))
            })
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}
