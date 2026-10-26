import PhotosUI
import PRCore
import PRImaging
import PRStorage
import SwiftUI

// Interface de la toile, organisée comme Procreate (barre du haut, colonne de curseurs, panneaux flottants),
// avec des icônes SF Symbols et une identité propre (rien n'est repris de Procreate).

extension CanvasSession {
    /// Message bref en haut de l'écran (annuler, rétablir, enregistrement…).
    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// Retour à la galerie : le projet est enregistré (avec sa vignette) avant.
    func returnToGallery() {
        strokeCancelled()
        if hasUnsavedChanges { saveProject(silently: true) }
        showingGallery = true
    }

    func openFromGallery(_ project: ProjectInfo) {
        openProject(project)
        showingGallery = false
    }

    func createProject(width: Int) {
        var prefs = preferences
        prefs.canvasWidth = width
        preferences = prefs
        newProject()
        showingGallery = false
    }

    /// Pinceau, doigt ou gomme : un premier toucher choisit l'outil, un second ouvre la bibliothèque (comme Procreate).
    func tapPaintTool(_ target: PaintTool) {
        if tool == target {
            showBrushes = true
        } else {
            tool = target
        }
    }
}

// MARK: - Barre du haut

struct TopBar: View {
    @Bindable var session: CanvasSession

    var body: some View {
        HStack(spacing: 14) {
            Button("Galerie") { session.returnToGallery() }
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.trailing, 6)

            BarCircleButton(symbol: "wrench.adjustable.fill", active: session.showActions) { session.showActions = true }
                .popover(isPresented: $session.showActions, arrowEdge: .top) { ActionsPanel(session: session) }
            BarCircleButton(symbol: "wand.and.stars", active: session.showAdjustments || session.activeFilter != nil) {
                session.showAdjustments = true
            }
            .popover(isPresented: $session.showAdjustments, arrowEdge: .top) { AdjustmentsPanel(session: session) }
            BarCircleButton(symbol: "lasso", active: session.tool == .select) {
                session.tool = session.tool == .select ? .brush : .select
            }
            BarCircleButton(symbol: "location.north.fill", active: session.transform != nil) {
                if session.transform == nil { session.startTransform() } else { session.applyTransform() }
            }

            Spacer(minLength: 8)
            ViewModeControl(session: session)
            Spacer(minLength: 8)

            BarToolButton(symbol: "paintbrush.pointed.fill", active: session.tool == .brush) { session.tapPaintTool(.brush) }
                .popover(isPresented: Binding(get: { session.showBrushes && session.tool == .brush },
                                              set: { session.showBrushes = $0 }), arrowEdge: .top) { BrushPanel(session: session) }
            BarToolButton(symbol: "hand.point.up.left.fill", active: session.tool == .smudge) { session.tapPaintTool(.smudge) }
                .popover(isPresented: Binding(get: { session.showBrushes && session.tool == .smudge },
                                              set: { session.showBrushes = $0 }), arrowEdge: .top) { BrushPanel(session: session) }
            BarToolButton(symbol: "eraser.fill", active: session.tool == .eraser) { session.tapPaintTool(.eraser) }
                .popover(isPresented: Binding(get: { session.showBrushes && session.tool == .eraser },
                                              set: { session.showBrushes = $0 }), arrowEdge: .top) { BrushPanel(session: session) }
            BarToolButton(symbol: "square.on.square.fill", active: session.showLayers) { session.showLayers = true }
                .popover(isPresented: $session.showLayers, arrowEdge: .top) {
                    LayersPanel(session: session).frame(width: 400, height: 620)
                }
            Button { session.showColorPicker = true } label: {
                Circle()
                    .fill(Color(.sRGB, red: session.color.x, green: session.color.y, blue: session.color.z))
                    .frame(width: 34, height: 34)
                    .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 2))
            }
            .popover(isPresented: $session.showColorPicker, arrowEdge: .top) { ColorPanel(session: session) }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(Color(white: 0.16))
    }
}

/// Bouton rond sombre de gauche (Actions, Ajustements, Sélection, Transformation).
struct BarCircleButton: View {
    let symbol: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(active ? Color.accentColor : Color(white: 0.08)))
        }
        .buttonStyle(.plain)
    }
}

/// Outil de droite : bleu quand il est actif.
struct BarToolButton: View {
    let symbol: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(active ? Color.accentColor : Color.white.opacity(0.85))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }
}

/// Vue sphère / dépliée / fenêtre plane, au centre de la barre.
struct ViewModeControl: View {
    @Bindable var session: CanvasSession

    var body: some View {
        HStack(spacing: 10) {
            Button {
                session.toggleUnfold()
            } label: {
                Label(session.mode == .unfolded ? "Replier" : "Déplier",
                      systemImage: session.mode == .unfolded ? "globe" : "rectangle.expand.vertical")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Menu {
                Picker("Vue", selection: Binding(get: { session.mode }, set: { session.setMode($0) })) {
                    ForEach(ViewMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if session.mode == .flat {
                    Section("Face") {
                        ForEach(CubeFace.allCases, id: \.self) { face in Button(face.label) { session.showFace(face) } }
                    }
                }
                if session.mode == .sphere {
                    Toggle("Horizon verrouillé", isOn: Binding(get: { session.horizonLocked }, set: { session.setHorizonLocked($0) }))
                }
            } label: {
                Text(session.mode == .unfolded ? session.mode.label : "\(session.mode.label) · \(Int(session.fovDegrees))°")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }
}

// MARK: - Colonne de gauche

/// Curseurs verticaux de taille et d'opacité, pipette, annuler / rétablir (comme la colonne de Procreate).
struct SideRail: View {
    @Bindable var session: CanvasSession

    var body: some View {
        VStack(spacing: 18) {
            RailSlider(value: $session.settings.radiusDegrees, range: 0.3...30)
            Button {
                session.showToast("Appui long sur la toile : pipette")
            } label: {
                RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.85), lineWidth: 2).frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            RailSlider(value: $session.settings.opacity, range: 0.02...1)
            Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!session.canUndo)
            Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!session.canRedo)
        }
        .font(.system(size: 20))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.vertical, 16)
        .frame(width: 54)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.16)))
    }
}

/// Glissière verticale en capsule, poignée claire.
struct RailSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    private let height: CGFloat = 230

    var body: some View {
        let t = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        ZStack(alignment: .bottom) {
            Capsule().fill(Color(white: 0.27)).frame(width: 40, height: height)
            Capsule().fill(Color(white: 0.85)).frame(width: 34, height: 22)
                .offset(y: -CGFloat(t) * (height - 26) - 2)
        }
        .frame(width: 40, height: height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            let f = min(1, max(0, 1 - Double(g.location.y / height)))
            value = range.lowerBound + f * (range.upperBound - range.lowerBound)
        })
    }
}

// MARK: - Barre contextuelle

/// Réglages de l'outil ou de l'opération en cours, sous la barre du haut.
struct ContextBar: View {
    @Bindable var session: CanvasSession

    var body: some View {
        Group {
            if session.transform != nil {
                TransformPanel(session: session)
            } else if session.distort != nil {
                DistortPanel(session: session)
            } else if session.activeFilter != nil {
                FilterPanel(session: session)
            } else if session.tool != .brush, session.tool != .eraser {
                HStack(spacing: 14) {
                    Label(session.tool.label, systemImage: session.tool.symbol).font(.callout.weight(.semibold))
                    ToolOptions(session: session)
                    Button("Terminer") { session.tool = .brush }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color(white: 0.16)))
            }
        }
        .foregroundStyle(.white)
    }
}

/// Message bref (annuler, rétablir…), comme le bandeau de Procreate.
struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.black.opacity(0.75)))
            .transition(.opacity)
    }
}

// MARK: - Ajustements

struct AdjustmentsPanel: View {
    @Bindable var session: CanvasSession

    var body: some View {
        PanelContainer(title: "Ajustements", width: 340) {
            PanelSection {
                ForEach(FilterKind.allCases.filter(\.isColorAdjustment)) { kind in
                    PanelRow(kind.label) { session.showAdjustments = false; session.openFilter(kind) }
                }
            }
            PanelSection {
                ForEach(FilterKind.allCases.filter { !$0.isColorAdjustment }) { kind in
                    PanelRow(kind.label) { session.showAdjustments = false; session.openFilter(kind) }
                }
            }
            PanelSection {
                ForEach([PaintTool.liquify, .clone, .fill, .gradient], id: \.self) { tool in
                    PanelRow(tool.label, symbol: tool.symbol) { session.showAdjustments = false; session.tool = tool }
                }
            }
        }
    }
}

// MARK: - Actions

enum ActionsTab: String, CaseIterable {
    case add, canvas, share, video, prefs, help

    var label: String {
        switch self {
        case .add: "Ajouter"
        case .canvas: "Toile"
        case .share: "Partager"
        case .video: "Vidéo"
        case .prefs: "Préfs"
        case .help: "Aide"
        }
    }

    var symbol: String {
        switch self {
        case .add: "plus.square.on.square"
        case .canvas: "globe"
        case .share: "square.and.arrow.up"
        case .video: "play.fill"
        case .prefs: "switch.2"
        case .help: "questionmark.circle"
        }
    }
}

struct ActionsPanel: View {
    @Bindable var session: CanvasSession
    @State private var tab: ActionsTab = .add
    @State private var photo: PhotosPickerItem?

    var body: some View {
        PanelContainer(title: "Actions", width: 400) {
            HStack(spacing: 0) {
                ForEach(ActionsTab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        VStack(spacing: 4) {
                            Image(systemName: t.symbol).font(.system(size: 20))
                            Text(t.label).font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(tab == t ? Color.accentColor : .white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 4)
            switch tab {
            case .add: addTab
            case .canvas: canvasTab
            case .share: shareTab
            case .video: videoTab
            case .prefs: prefsTab
            case .help: helpTab
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            session.showActions = false
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { session.loadImport(data: data, name: "Photo") }
            }
        }
    }

    private var addTab: some View {
        Group {
            PanelSection {
                PanelRow("Insérer un fichier") { session.showActions = false; session.showImporter = true }
                PhotosPicker(selection: $photo, matching: .images) {
                    PanelRowLabel("Insérer une photo")
                }
                .buttonStyle(.plain)
                PanelRow("Ajouter du texte") { session.showActions = false; session.showTextSheet = true }
            }
            PanelSection {
                PanelRow("Coller une image") { session.showActions = false; session.pasteImport() }
            }
        }
    }

    private var canvasTab: some View {
        Group {
            PanelSection {
                PanelToggle("Guides (grille sphérique)", isOn: $session.guidesEnabled)
                Picker("Espacement des guides", selection: $session.guideSpacing) {
                    ForEach([10.0, 15.0, 30.0, 45.0], id: \.self) { Text("\(Int($0))°").tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14).padding(.vertical, 8)
                Menu {
                    ForEach(SymmetrySettings.Kind.allCases, id: \.self) { kind in Button(kind.label) { session.setSymmetry(kind) } }
                } label: {
                    PanelRowLabel("Symétrie : \(session.symmetry.kind.label)")
                }
                PanelRow("Tourner la sphère…") { session.showActions = false; session.showRotation = true }
            }
            PanelSection {
                Menu {
                    ForEach(ToneMapping.allCases, id: \.self) { curve in Button(curve.label) { session.toneMapping = curve } }
                } label: { PanelRowLabel("Affichage : \(session.toneMapping.label)") }
                HStack {
                    Text("Exposition").foregroundStyle(.white.opacity(0.85))
                    Slider(value: $session.exposure, in: -4...4)
                    Text(String(format: "%+.1f", session.exposure)).monospacedDigit().frame(width: 40)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                Menu {
                    ForEach(BlendSpace.allCases, id: \.self) { space in Button(space.label) { session.setBlendSpace(space) } }
                } label: { PanelRowLabel("Fusion : \(session.blendSpace.label)") }
            }
            PanelSection {
                PanelRow("Instantanés…") { session.showActions = false; session.showSnapshots = true }
                PanelRow("Enregistrer maintenant") { session.saveProject() }
            }
        }
    }

    private var shareTab: some View {
        Group {
            PanelSection {
                ForEach(ExportKind.allCases, id: \.self) { kind in
                    PanelRow(kind.label) {
                        session.exportKind = kind
                        session.showActions = false
                        session.showExport = true
                    }
                }
            }
            PanelSection {
                PanelRow("Cubemap, lot de résolutions, orientation…") {
                    session.showActions = false
                    session.showExport = true
                }
            }
        }
    }

    private var videoTab: some View {
        PanelSection {
            PanelToggle("Enregistrer le timelapse", isOn: $session.timelapseEnabled)
            PanelRow("Exporter la vidéo (\(session.timelapseFrames) images)…") {
                session.showActions = false
                session.showTimelapse = true
            }
        }
    }

    private var prefsTab: some View {
        Group {
            PanelSection {
                Menu {
                    ForEach(Preferences.Theme.allCases, id: \.self) { theme in Button(theme.label) { session.preferences.theme = theme } }
                } label: { PanelRowLabel("Thème : \(session.preferences.theme.label)") }
                PanelToggle("Mode gaucher", isOn: $session.preferences.leftHanded)
                PanelToggle("QuickShape (tracer puis maintenir)", isOn: $session.quickShapeEnabled)
                PanelToggle("Pression → taille", isOn: $session.settings.pressureAffectsSize)
                PanelToggle("Pression → opacité", isOn: $session.settings.pressureAffectsOpacity)
            }
            PanelSection {
                PanelRow("Toutes les préférences…") { session.showActions = false; session.showPreferences = true }
            }
        }
    }

    private var helpTab: some View {
        PanelSection {
            VStack(alignment: .leading, spacing: 8) {
                helpLine("Pencil", session.preferences.fingerPainting ? "peindre (le doigt aussi)" : "peindre (seul le Pencil dessine)")
                helpLine(session.preferences.fingerPainting ? "2 doigts glissés" : "1 ou 2 doigts glissés", "regarder autour (tourner la sphère)")
                helpLine("Pincer", "zoomer (champ de vision)")
                helpLine("2 doigts tournés", "pencher la vue (horizon déverrouillé)")
                helpLine("Double tap 2 doigts", session.preferences.twoFingerDoubleTap.label)
                helpLine("Double tap 3 doigts", session.preferences.threeFingerDoubleTap.label)
                helpLine("Tap 4 doigts", session.preferences.fourFingerTap.label)
                helpLine("Appui long au doigt", "pipette")
                helpLine("Déplier", "voir tout le panorama à plat")
            }
            .padding(14)
        }
    }

    private func helpLine(_ gesture: String, _ effect: String) -> some View {
        HStack(alignment: .top) {
            Text(gesture).fontWeight(.semibold).frame(width: 150, alignment: .leading)
            Text(effect).foregroundStyle(.white.opacity(0.75))
        }
        .font(.callout)
    }
}

// MARK: - Briques des panneaux

/// Panneau flottant sombre à coins arrondis, titre en gras.
struct PanelContainer<Content: View>: View {
    let title: String
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.system(size: 28, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                content
            }
            .padding(20)
        }
        .frame(width: width)
        .frame(maxHeight: 700)
        .background(Color(white: 0.2))
        .environment(\.colorScheme, .dark)
        .presentationCompactAdaptation(.popover)
    }
}

/// Groupe de lignes sur fond plus sombre.
struct PanelSection<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.15)))
    }
}

struct PanelRowLabel: View {
    let text: String
    var symbol: String?

    init(_ text: String, symbol: String? = nil) {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 10) {
            if let symbol { Image(systemName: symbol).frame(width: 22) }
            Text(text)
            Spacer()
        }
        .font(.system(size: 18))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

struct PanelRow: View {
    let text: String
    var symbol: String?
    let action: () -> Void

    init(_ text: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.text = text
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) { PanelRowLabel(text, symbol: symbol) }
            .buttonStyle(.plain)
    }
}

struct PanelToggle: View {
    let text: String
    @Binding var isOn: Bool

    init(_ text: String, isOn: Binding<Bool>) {
        self.text = text
        _isOn = isOn
    }

    var body: some View {
        Toggle(text, isOn: $isOn)
            .font(.system(size: 18))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
    }
}
