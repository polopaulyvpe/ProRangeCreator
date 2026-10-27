import PRCore
import PRImaging
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Sections de l'Atelier de pinceaux, dans l'ordre de Procreate.
enum StudioSection: String, CaseIterable, Identifiable {
    case strokePath, stabilization, taper, shape, grain, rendering, wetMix, colorDynamics, dynamics, pencil, properties, materials, preview, about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .strokePath: "Tracé du trait"
        case .stabilization: "Stabilisation"
        case .taper: "Effilement"
        case .shape: "Forme"
        case .grain: "Grain"
        case .rendering: "Rendu"
        case .wetMix: "Mélange humide"
        case .colorDynamics: "Dynamique de couleur"
        case .dynamics: "Dynamique"
        case .pencil: "Apple Pencil"
        case .properties: "Propriétés"
        case .materials: "Matériaux"
        case .preview: "Aperçu"
        case .about: "À propos de ce pinceau"
        }
    }

    var symbol: String {
        switch self {
        case .strokePath: "point.topleft.down.to.point.bottomright.curvepath"
        case .stabilization: "waveform.path"
        case .taper: "scribble"
        case .shape: "seal.fill"
        case .grain: "square.grid.3x3.fill"
        case .rendering: "mountain.2.fill"
        case .wetMix: "drop.fill"
        case .colorDynamics: "fanblades.fill"
        case .dynamics: "gauge.with.dots.needle.33percent"
        case .pencil: "applepencil"
        case .properties: "list.bullet"
        case .materials: "cube"
        case .preview: "rectangle.portrait.on.rectangle.portrait"
        case .about: "info.circle.fill"
        }
    }
}

extension CanvasSession {
    /// Image (PNG ou autre) en forme ou grain, sans l'appliquer.
    func loadBrushTexture(_ url: URL, invert: Bool) -> BrushTexture? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let image = try? ImageDecoder.decode(url) else {
            fileMessage = "Image illisible"
            return nil
        }
        return BrushTextureImport.texture(from: image, name: url.deletingPathExtension().lastPathComponent, invert: invert)
    }
}

/// L'Atelier : sections à gauche, réglages au centre, bloc à dessin à droite ; Annuler ou valider (✓).
struct BrushStudioView: View {
    @Bindable var session: CanvasSession
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BrushSettings
    @State private var section: StudioSection = .shape
    @State private var clearToken = 0
    @State private var importing: (asGrain: Bool, invert: Bool)?
    @State private var showImporter = false

    init(session: CanvasSession) {
        self.session = session
        var settings = session.settings
        if settings.grainSource == nil { settings.grainSource = settings.grain }
        _draft = State(initialValue: settings)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            settingsColumn
            pad
        }
        .background(Color(white: 0.1).ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result, let request = importing,
                  let texture = session.loadBrushTexture(url, invert: request.invert) else { return }
            if request.asGrain {
                draft.grainSource = texture
                draft.refreshGrain()
            } else {
                draft.shape = texture
            }
        }
    }

    // MARK: - Colonnes

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Atelier de pinceaux").font(.system(size: 26, weight: .bold)).foregroundStyle(.white.opacity(0.9))
            if let image = FlatBrushPainter.preview(draft, width: 240, height: 80, radiusPixels: 16) {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .padding(.vertical, 6)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(StudioSection.allCases) { s in
                        Button { section = s } label: {
                            HStack(spacing: 14) {
                                Image(systemName: s.symbol).frame(width: 24)
                                Text(s.label).font(.system(size: 18))
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .foregroundStyle(s == .materials ? Color.white.opacity(0.35) : Color.white.opacity(0.85))
                            .background(RoundedRectangle(cornerRadius: 22).fill(section == s ? Color.accentColor : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color(white: 0.15)).padding(8))
    }

    private var settingsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(draft.name).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                content
            }
            .padding(22)
        }
        .frame(width: 330)
    }

    private var pad: some View {
        ZStack(alignment: .top) {
            BrushPadView(settings: draft, clearToken: clearToken)
                .ignoresSafeArea()
            HStack(spacing: 14) {
                Menu {
                    Button("Effacer le bloc à dessin", systemImage: "trash") { clearToken += 1 }
                } label: {
                    Label("Bloc à dessin", systemImage: "scribble.variable")
                        .font(.system(size: 18, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .background(Capsule().stroke(Color.white.opacity(0.2)))
                }
                Spacer()
                Button("Annuler") { dismiss() }
                    .font(.system(size: 18))
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(Capsule().stroke(Color.white.opacity(0.2)))
                Button {
                    session.settings = draft
                    session.showToast(draft.name)
                    dismiss()
                } label: {
                    Image(systemName: "checkmark").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 54, height: 54).background(Circle().fill(Color.accentColor))
                }
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(20)
        }
    }

    // MARK: - Sections

    @ViewBuilder private var content: some View {
        switch section {
        case .strokePath: strokePath
        case .stabilization: stabilization
        case .taper: taper
        case .shape: shape
        case .grain: grain
        case .rendering: upcoming("Modes de rendu (glacis léger, uniforme, intense…), flux, bords humides et brûlés, mode de fusion : prochain lot.")
        case .wetMix: upcoming("Dilution, charge, attaque, tirage, grade, flou : le pinceau se mélangera à la peinture déjà posée. Dernier lot.")
        case .colorDynamics: upcoming("Variation de teinte, saturation, luminosité par tampon ou par trait, couleur secondaire : prochain lot.")
        case .dynamics: dynamics
        case .pencil: pencil
        case .properties: properties
        case .materials: upcoming("Métal et rugosité servent aux modèles 3D de Procreate : sans effet sur la peinture d'un panorama.")
        case .preview: previewSection
        case .about: about
        }
    }

    private var taper: some View {
        StudioCard {
            StudioSlider("Longueur", value: $draft.taperStartLength, range: 0...10) { $0 == 0 ? "Aucune" : String(format: "%.1f ⌀", $0) }
            StudioSlider("Taille", value: $draft.taperSize, range: 0...1)
            StudioSlider("Opacité", value: $draft.taperOpacity, range: 0...1)
            Text("Effilement au début du trait. La fin suit la pression du Pencil.")
                .font(.caption).foregroundStyle(.white.opacity(0.5))
        }
    }

    private var shape: some View {
        Group {
            StudioCard {
                HStack {
                    if let texture = draft.shape { TexturePreview(texture: texture).frame(width: 90, height: 90) }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(draft.shape?.name ?? "Ronde (dureté)").font(.headline)
                        Button("Importer une image…") { importing = (false, false); showImporter = true }
                        Button("Importer, inversée…") { importing = (false, true); showImporter = true }
                        if draft.shape != nil { Button("Retirer", role: .destructive) { draft.shape = nil } }
                    }
                }
                if draft.shape == nil {
                    StudioSlider("Dureté", value: $draft.hardness, range: 0...1)
                }
            }
            StudioCard {
                StudioSlider("Angle", value: $draft.shapeRotationDegrees, range: -180...180) { "\(Int($0))°" }
                Toggle("Suit la direction du trait", isOn: $draft.followStroke)
                StudioSlider("Dispersion", value: $draft.rotationJitter, range: 0...Double.pi) { "±\(Int($0 * 180 / .pi))°" }
                Toggle("Angle de départ aléatoire", isOn: $draft.randomizeRotation)
                Toggle("Retournement aléatoire", isOn: $draft.randomFlip)
            }
            StudioCard {
                StudioSlider("Nombre", value: Binding(get: { Double(draft.stampCount) }, set: { draft.stampCount = Int($0.rounded()) }),
                             range: 1...16) { "\(Int($0))" }
                StudioSlider("Variation du nombre", value: $draft.stampCountJitter, range: 0...1)
                StudioSlider("Rondeur", value: $draft.shapeRoundness, range: 0.05...1)
            }
        }
    }

    private var grain: some View {
        Group {
            StudioCard {
                HStack {
                    if let texture = draft.grain { TexturePreview(texture: texture).frame(width: 90, height: 90) }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(draft.grainSource?.name ?? "Aucun grain").font(.headline)
                        Button("Importer une image…") { importing = (true, false); showImporter = true }
                        if draft.grainSource != nil {
                            Button("Retirer", role: .destructive) {
                                draft.grainSource = nil
                                draft.grain = nil
                            }
                        }
                    }
                }
                Picker("Comportement", selection: $draft.grainMoving) {
                    Text("Mobile").tag(true)
                    Text("Texturé").tag(false)
                }
                .pickerStyle(.segmented)
            }
            StudioCard {
                StudioSlider("Échelle", value: $draft.grainScaleDegrees, range: 0.2...30) { String(format: "%.1f°", $0) }
                StudioSlider("Rotation", value: $draft.grainRotationDegrees, range: -180...180) { "\(Int($0))°" }
                StudioSlider("Profondeur", value: $draft.grainDepth, range: 0...1)
                StudioSlider("Profondeur minimale", value: $draft.grainDepthMinimum, range: 0...1)
                StudioSlider("Variation de profondeur", value: $draft.grainDepthJitter, range: 0...1)
                Toggle("Décalage aléatoire", isOn: $draft.grainOffsetJitter)
            }
            StudioCard {
                StudioSlider("Contraste", value: $draft.grainContrast, range: -1...1, signed: true)
                StudioSlider("Luminosité", value: $draft.grainBrightness, range: -1...1, signed: true)
                Toggle("Inverser", isOn: $draft.grainInverted)
            }
            .onChange(of: draft.grainContrast) { draft.refreshGrain() }
            .onChange(of: draft.grainBrightness) { draft.refreshGrain() }
            .onChange(of: draft.grainInverted) { draft.refreshGrain() }
        }
    }

    private var strokePath: some View {
        StudioCard {
            StudioSlider("Espacement", value: $draft.spacing, range: 0.02...4) { "\(Int($0 * 50)) %" }
            StudioSlider("Variation d'espacement", value: $draft.spacingJitter, range: 0...1)
            StudioSlider("Dispersion latérale", value: $draft.scatter, range: 0...2)
        }
    }

    private var stabilization: some View {
        Group {
            StudioCard {
                Text("StreamLine").font(.headline)
                StudioSlider("Quantité", value: $draft.streamLine, range: 0...1)
                Text("Le trait suit la main avec un léger retard, ce qui lisse les courbes ; il rattrape la main au lever du stylet.")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
            }
            StudioCard {
                Text("Stabilisation").font(.headline)
                StudioSlider("Quantité", value: $draft.stabilization, range: 0...1)
                Text("Moyenne des derniers points : gomme les tremblements, surtout quand on trace lentement.")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
            }
            StudioCard {
                Text("Filtrage du mouvement").font(.headline)
                StudioSlider("Quantité", value: $draft.motionFiltering, range: 0...1)
                Text("Ignore les petits écarts de la main autour du trait.")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
            }
            StudioCard {
                Text("Pression").font(.headline)
                StudioSlider("Lissage", value: $draft.pressureSmoothing, range: 0...1)
            }
        }
    }

    private var dynamics: some View {
        Group {
            StudioCard {
                StudioSlider("Vitesse → taille", value: $draft.speedSize, range: -1...1, signed: true)
                StudioSlider("Vitesse → opacité", value: $draft.speedOpacity, range: -1...1, signed: true)
            }
            StudioCard {
                StudioSlider("Variation de taille", value: $draft.sizeJitter, range: 0...1)
                StudioSlider("Variation d'opacité", value: $draft.opacityJitter, range: 0...1)
            }
        }
    }

    private var pencil: some View {
        Group {
            StudioCard {
                Text("Pression").font(.headline)
                StudioSlider("Taille", value: Binding(get: { draft.pressureAffectsSize ? draft.pressureSizeAmount : 0 },
                                                      set: { draft.pressureSizeAmount = $0; draft.pressureAffectsSize = $0 > 0 }),
                             range: 0...1)
                StudioSlider("Taille minimale", value: $draft.minimumSize, range: 0...1)
                StudioSlider("Opacité", value: Binding(get: { draft.pressureAffectsOpacity ? draft.pressureOpacityAmount : 0 },
                                                         set: { draft.pressureOpacityAmount = $0; draft.pressureAffectsOpacity = $0 > 0 }),
                             range: 0...1)
            }
            StudioCard {
                Text("Inclinaison").font(.headline)
                StudioSlider("Angle", value: $draft.tiltAngleDegrees, range: 0...89) { "\(Int($0))°" }
                StudioSlider("Opacité", value: $draft.tiltOpacity, range: 0...1)
                StudioSlider("Taille", value: $draft.tiltSize, range: 0...2)
            }
        }
    }

    private var properties: some View {
        StudioCard {
            StudioSlider("Taille maximale", value: $draft.maxSizeDegrees, range: 1...60) { String(format: "%.1f°", $0) }
            StudioSlider("Taille minimale", value: $draft.minSizeDegrees, range: 0.05...10) { String(format: "%.2f°", $0) }
            StudioSlider("Opacité maximale", value: $draft.maxOpacity, range: 0.05...1)
            StudioSlider("Opacité minimale", value: $draft.minOpacity, range: 0...1)
            Text("Bornes des curseurs de taille et d'opacité de la colonne de gauche.")
                .font(.caption).foregroundStyle(.white.opacity(0.5))
        }
        .onChange(of: draft.maxSizeDegrees) { draft.radiusDegrees = min(draft.radiusDegrees, draft.maxSizeDegrees) }
        .onChange(of: draft.maxOpacity) { draft.opacity = min(draft.opacity, draft.maxOpacity) }
    }

    private var previewSection: some View {
        StudioCard {
            if let image = FlatBrushPainter.preview(draft, width: 300, height: 120, radiusPixels: 24) {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            }
            Text("Aperçu à taille fixe ; le bloc à dessin montre la taille réelle.")
                .font(.caption).foregroundStyle(.white.opacity(0.5))
        }
    }

    private var about: some View {
        Group {
            StudioCard {
                TextField("Nom du pinceau", text: $draft.name).font(.title3)
                TextField("Auteur", text: $draft.author)
            }
            StudioCard {
                Button("Créer un point de réinitialisation") {
                    session.brushResetPoints[draft.name] = BrushResetPoint(settings: draft, date: Date())
                }
                if let point = session.brushResetPoints[draft.name] {
                    Button("Réinitialiser le pinceau") { draft = point.settings }
                    Text("Dernier point de réinitialisation : \(point.date.formatted(date: .numeric, time: .shortened))")
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
            StudioCard {
                Button("Enregistrer dans Mes pinceaux", systemImage: "square.and.arrow.down") {
                    session.saveBrush(BrushPreset(name: draft.name, settings: draft))
                    session.showToast("« \(draft.name) » enregistré")
                }
            }
        }
    }

    private func upcoming(_ text: String) -> some View {
        StudioCard {
            Label("Bientôt", systemImage: "clock").font(.headline)
            Text(text).font(.callout).foregroundStyle(.white.opacity(0.6))
        }
    }
}

/// Point de réinitialisation d'un pinceau (réglages et date).
struct BrushResetPoint {
    let settings: BrushSettings
    let date: Date
}

/// Carte sombre qui regroupe des réglages.
struct StudioCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color(white: 0.17)))
            .foregroundStyle(.white.opacity(0.85))
    }
}

/// Curseur de l'Atelier : nom à gauche, valeur à droite, glissière dessous.
struct StudioSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, signed: Bool = false,
         format: ((Double) -> String)? = nil) {
        self.title = title
        _value = value
        self.range = range
        self.format = format ?? { v in
            let percent = Int((v * 100).rounded())
            if signed { return percent > 0 ? "+\(percent) %" : "\(percent) %" }
            return percent == 0 ? "Aucun" : percent == 100 ? "Max" : "\(percent) %"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.white.opacity(0.6))
            }
            .font(.system(size: 16))
            Slider(value: $value, in: range)
        }
    }
}

// MARK: - Bloc à dessin

/// Bloc à dessin de l'Atelier : on y essaie le pinceau en cours de réglage (Pencil ou doigt, pression et inclinaison).
struct BrushPadView: UIViewRepresentable {
    let settings: BrushSettings
    let clearToken: Int

    func makeUIView(context: Context) -> BrushPadUIView { BrushPadUIView() }

    func updateUIView(_ view: BrushPadUIView, context: Context) {
        view.settings = settings
        if view.clearToken != clearToken {
            view.clearToken = clearToken
            view.clear()
        }
    }
}

final class BrushPadUIView: UIView {
    var settings = BrushSettings.defaultBrush {
        didSet { painter?.settings = settings }
    }
    var clearToken = 0
    private var painter: FlatBrushPainter?
    /// Le bloc est peint à demi-résolution puis agrandi : assez fin pour juger, assez léger pour suivre le Pencil.
    private let scale: CGFloat = 0.5
    /// Échelle : 4 pixels du bloc par degré de pinceau.
    private let pixelsPerRadian = 4 * 180 / Double.pi

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.12, alpha: 1)
        isMultipleTouchEnabled = false
        layer.contentsGravity = .resize
        layer.magnificationFilter = .linear
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        ensurePainter()
    }

    private func ensurePainter() {
        let w = max(1, Int(bounds.width * scale)), h = max(1, Int(bounds.height * scale))
        guard painter?.width != w || painter?.height != h else { return }
        painter = FlatBrushPainter(width: w, height: h, settings: settings, pixelsPerRadian: pixelsPerRadian)
        refresh()
    }

    func clear() {
        painter?.clear()
        refresh()
    }

    private func refresh() {
        layer.contents = painter?.image()
    }

    /// Même stabilisation que sur la toile ; l'unité est la demi-hauteur du bloc.
    private var stabilizer: StrokeStabilizer?
    private var lastTilt = 0.0
    private var lastTime: TimeInterval = 0

    private func add(_ touch: UITouch) {
        let p = touch.location(in: self)
        let pressure = touch.type == .pencil && touch.maximumPossibleForce > 0 ? Double(touch.force / touch.maximumPossibleForce) : 1
        let tilt = touch.type == .pencil ? min(1, max(0, 1 - Double(touch.altitudeAngle) / (.pi / 2))) : 0
        var point = SIMD2<Double>(Double(p.x * scale), Double(p.y * scale))
        var pressed = pressure
        if stabilizer != nil {
            let stable = stabilizer!.add(point, pressure: pressure)
            point = stable.point
            pressed = stable.pressure
        }
        lastTilt = tilt
        lastTime = touch.timestamp
        painter?.addPoint(point, pressure: pressed, tilt: tilt, time: touch.timestamp)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        ensurePainter()
        guard let touch = touches.first else { return }
        painter?.begin(seed: UInt64.random(in: 1...UInt64.max))
        stabilizer = settings.stabilizer.isActive
            ? StrokeStabilizer(settings: settings.stabilizer, unit: Double(bounds.height * scale) / 2) : nil
        add(touch)
        refresh()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard var pending = stabilizer else { return }
        stabilizer = nil
        for point in pending.finish(step: 1) {
            lastTime += 0.002
            painter?.addPoint(point.point, pressure: point.pressure, tilt: lastTilt, time: lastTime)
        }
        refresh()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        stabilizer = nil
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        for t in event?.coalescedTouches(for: touch) ?? [touch] { add(t) }
        refresh()
    }
}
