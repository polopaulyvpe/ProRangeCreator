import Foundation

extension ToneMapping: Codable {}

/// Action déclenchée par un geste (remappable dans les préférences).
public enum GestureAction: String, Codable, CaseIterable, Sendable {
    case undo
    case redo
    case toggleInterface
    case toggleUnfold
    case none

    public var label: String {
        switch self {
        case .undo: "Annuler"
        case .redo: "Rétablir"
        case .toggleInterface: "Masquer / afficher l'interface"
        case .toggleUnfold: "Déplier / replier"
        case .none: "Rien"
        }
    }
}

/// Préférences de l'app, enregistrées en JSON. Le décodage tolère les champs absents (valeur par défaut) :
/// une préférence ajoutée plus tard ne fait pas perdre les autres.
public struct Preferences: Codable, Equatable, Sendable {
    public enum Theme: String, Codable, CaseIterable, Sendable {
        case dark
        case light
        case system

        public var label: String {
            switch self {
            case .dark: "Sombre"
            case .light: "Clair"
            case .system: "Comme le système"
            }
        }
    }

    public var theme: Theme = .dark
    /// Curseurs de taille et d'opacité à droite.
    public var leftHanded = false
    /// Courbe de pression p^γ : γ > 1 il faut appuyer plus fort, γ < 1 le trait réagit plus vite.
    public var pressureGamma = 1.0
    public var twoFingerDoubleTap: GestureAction = .undo
    public var threeFingerDoubleTap: GestureAction = .redo
    public var fourFingerTap: GestureAction = .toggleInterface
    /// Maintien à deux doigts : annulation rapide continue.
    public var rapidUndoHold = true
    /// Appui long d'un doigt : pipette.
    public var eyedropperHold = true
    /// Fusion des nouveaux projets (D4).
    public var blendSpace: BlendSpace = .perceptual
    /// Courbe d'affichage au lancement (D12).
    public var toneMapping: ToneMapping = .clip
    /// Plafond de l'historique, en pas.
    public var historyLimit = 1000
    /// Largeur des nouveaux projets (2:1).
    public var canvasWidth = 8192

    public static let historyLimits = [100, 250, 500, 1000, 2000]
    public static let canvasWidths = [2048, 4096, 8192]

    public init() {}

    public func mappedPressure(_ p: Double) -> Double {
        pow(min(1, max(0, p)), min(4, max(0.25, pressureGamma)))
    }

    enum CodingKeys: String, CodingKey {
        case theme, leftHanded, pressureGamma, twoFingerDoubleTap, threeFingerDoubleTap, fourFingerTap
        case rapidUndoHold, eyedropperHold, blendSpace, toneMapping, historyLimit, canvasWidth
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        theme = (try? c.decodeIfPresent(Theme.self, forKey: .theme)) ?? d.theme
        leftHanded = (try? c.decodeIfPresent(Bool.self, forKey: .leftHanded)) ?? d.leftHanded
        pressureGamma = (try? c.decodeIfPresent(Double.self, forKey: .pressureGamma)) ?? d.pressureGamma
        twoFingerDoubleTap = (try? c.decodeIfPresent(GestureAction.self, forKey: .twoFingerDoubleTap)) ?? d.twoFingerDoubleTap
        threeFingerDoubleTap = (try? c.decodeIfPresent(GestureAction.self, forKey: .threeFingerDoubleTap)) ?? d.threeFingerDoubleTap
        fourFingerTap = (try? c.decodeIfPresent(GestureAction.self, forKey: .fourFingerTap)) ?? d.fourFingerTap
        rapidUndoHold = (try? c.decodeIfPresent(Bool.self, forKey: .rapidUndoHold)) ?? d.rapidUndoHold
        eyedropperHold = (try? c.decodeIfPresent(Bool.self, forKey: .eyedropperHold)) ?? d.eyedropperHold
        blendSpace = (try? c.decodeIfPresent(BlendSpace.self, forKey: .blendSpace)) ?? d.blendSpace
        toneMapping = (try? c.decodeIfPresent(ToneMapping.self, forKey: .toneMapping)) ?? d.toneMapping
        historyLimit = (try? c.decodeIfPresent(Int.self, forKey: .historyLimit)) ?? d.historyLimit
        canvasWidth = (try? c.decodeIfPresent(Int.self, forKey: .canvasWidth)) ?? d.canvasWidth
    }

    /// Lecture tolérante : des données absentes ou illisibles donnent les valeurs par défaut.
    public static func decode(_ data: Data?) -> Preferences {
        guard let data, let prefs = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return prefs
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}
