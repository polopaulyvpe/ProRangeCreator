import PRCore
import SwiftUI

extension CanvasSession {
    /// Geste remappé (préférences) → action.
    func perform(_ action: GestureAction) {
        switch action {
        case .undo: undo()
        case .redo: redo()
        case .toggleInterface: interfaceHidden.toggle()
        case .toggleUnfold: toggleUnfold()
        case .none: break
        }
    }

    /// Au lancement : courbe d'affichage et fusion par défaut, avant la réouverture du dernier projet.
    func applyLaunchPreferences() {
        toneMapping = preferences.toneMapping
        setBlendSpace(preferences.blendSpace)
    }

    var colorScheme: ColorScheme? {
        switch preferences.theme {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

struct PreferencesSheet: View {
    @Bindable var session: CanvasSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Interface") {
                    Picker("Thème", selection: $session.preferences.theme) {
                        ForEach(Preferences.Theme.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("Mode gaucher (curseurs à droite)", isOn: $session.preferences.leftHanded)
                }
                Section {
                    LabeledContent("Courbe") {
                        Slider(value: $session.preferences.pressureGamma, in: 0.4...2.5)
                        Text(String(format: "%.2f", session.preferences.pressureGamma)).monospacedDigit().frame(width: 44)
                    }
                    PressureCurvePreview(gamma: session.preferences.pressureGamma)
                        .frame(height: 120)
                    Button("Linéaire") { session.preferences.pressureGamma = 1 }
                } header: {
                    Text("Pression du Pencil")
                } footer: {
                    Text("À gauche, le trait réagit dès un appui léger ; à droite, il faut appuyer plus fort pour atteindre la taille et l'opacité maximales.")
                }
                Section("Gestes") {
                    Picker("Tap à 2 doigts", selection: $session.preferences.twoFingerDoubleTap) { actions }
                    Picker("Tap à 3 doigts", selection: $session.preferences.threeFingerDoubleTap) { actions }
                    Picker("Tap à 4 doigts", selection: $session.preferences.fourFingerTap) { actions }
                    Toggle("Maintien à 2 doigts : annulation rapide", isOn: $session.preferences.rapidUndoHold)
                    Toggle("Appui long : pipette", isOn: $session.preferences.eyedropperHold)
                    Toggle("Dessiner aussi au doigt (sinon : Pencil seul)", isOn: $session.preferences.fingerPainting)
                }
                Section {
                    Picker("Fusion des couleurs", selection: $session.preferences.blendSpace) {
                        ForEach(BlendSpace.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Affichage au lancement", selection: $session.preferences.toneMapping) {
                        ForEach(ToneMapping.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Taille des nouveaux projets", selection: $session.preferences.canvasWidth) {
                        ForEach(Preferences.canvasWidths, id: \.self) { w in Text("\(w / 1024)K (\(w) × \(w / 2))").tag(w) }
                    }
                    Picker("Historique", selection: $session.preferences.historyLimit) {
                        ForEach(Preferences.historyLimits, id: \.self) { Text("\($0) pas").tag($0) }
                    }
                } header: {
                    Text("Projets")
                } footer: {
                    Text("Fusion, taille et historique s'appliquent aux nouveaux projets. Pas d'affichage EDR : l'écran de l'iPad Air 5 n'est pas HDR.")
                }
            }
            .navigationTitle("Préférences")
            .toolbar { Button("Fermer") { dismiss() } }
        }
    }

    @ViewBuilder private var actions: some View {
        ForEach(GestureAction.allCases, id: \.self) { Text($0.label).tag($0) }
    }
}

/// Courbe p^γ dessinée de 0 à 1.
private struct PressureCurvePreview: View {
    let gamma: Double

    var body: some View {
        Canvas { context, size in
            var frame = Path()
            frame.addRect(CGRect(origin: .zero, size: size))
            context.stroke(frame, with: .color(.secondary.opacity(0.4)))
            var curve = Path()
            for i in 0...64 {
                let p = Double(i) / 64
                let point = CGPoint(x: p * size.width, y: (1 - pow(p, gamma)) * size.height)
                if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            context.stroke(curve, with: .color(.accentColor), lineWidth: 2)
        }
    }
}
