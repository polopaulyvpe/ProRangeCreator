import simd

/// Les trois vues de la toile (D5).
public enum ViewMode: String, CaseIterable, Sendable {
    /// Caméra au centre de la sphère, projection rectiligne.
    case sphere
    /// Panorama équirectangulaire à plat.
    case unfolded
    /// Vue rectiligne verrouillée face à une direction, pour peindre comme sur une image plate.
    case flat

    public var label: String {
        switch self {
        case .sphere: "Sphère"
        case .unfolded: "Dépliée"
        case .flat: "Fenêtre"
        }
    }
}

/// Les six faces proposées en raccourci pour la fenêtre plane.
public enum CubeFace: String, CaseIterable, Sendable {
    case front, right, back, left, up, down

    public var label: String {
        switch self {
        case .front: "Avant"
        case .right: "Droite"
        case .back: "Arrière"
        case .left: "Gauche"
        case .up: "Haut"
        case .down: "Bas"
        }
    }

    public var yaw: Double {
        switch self {
        case .front, .up, .down: 0
        case .right: .pi / 2
        case .back: .pi
        case .left: -.pi / 2
        }
    }

    public var pitch: Double {
        switch self {
        case .up: .pi / 2
        case .down: -.pi / 2
        default: 0
        }
    }
}

/// Courbe d'affichage des valeurs linéaires (D12 : écrêtage par défaut).
public enum ToneMapping: Int, CaseIterable, Sendable {
    case clip = 0
    case agx = 1
    case aces = 2
    case filmic = 3

    public var label: String {
        switch self {
        case .clip: "Écrêtage"
        case .agx: "AgX"
        case .aces: "ACES"
        case .filmic: "Filmique"
        }
    }
}

/// Paramètres de projection résolus pour un cadre : exactement ce que reçoit le shader, en double précision.
/// `direction(ndc:)` est l'implémentation de référence CPU du calcul fait par pixel sur le GPU.
public struct ProjectionParameters: Sendable, Equatable {
    /// Caméra → monde (colonnes : droite, haut, arrière ; la caméra regarde vers -Z).
    public var rotation: simd_double3x3
    public var tanHalfFov: Double
    /// Largeur / hauteur de l'écran.
    public var aspect: Double
    /// Décalage du point principal (fenêtre plane), en unités du plan image à distance 1.
    public var shift: SIMD2<Double>
    /// uv équirectangulaire au centre de l'écran en vue dépliée.
    public var unfoldedCenter: SIMD2<Double>
    /// Hauteur visible en vue dépliée, en unités de v (1 = toute la hauteur du panorama).
    public var unfoldedSpan: Double
    /// 0 = projection rectiligne, 1 = vue dépliée ; entre les deux, morphing.
    public var morph: Double

    /// Direction vue en un point de l'écran (NDC : x vers la droite, y vers le haut, dans [-1, 1]).
    /// `nil` hors du panorama en vue dépliée.
    public func direction(ndc p: SIMD2<Double>) -> Vec3? {
        let uv = unfoldedUV(ndc: p)
        if morph >= 0.999 {
            guard uv.y >= 0, uv.y <= 1 else { return nil }
            return Equirect.direction(u: uv.x, v: uv.y)
        }
        let rect = rectilinearDirection(ndc: p)
        if morph <= 0 { return rect }
        let flat = Equirect.direction(u: uv.x, v: min(1, max(0, uv.y)))
        return simd_normalize(rect * (1 - morph) + flat * morph)
    }

    public func rectilinearDirection(ndc p: SIMD2<Double>) -> Vec3 {
        let camera = simd_normalize(Vec3(p.x * aspect * tanHalfFov + shift.x, p.y * tanHalfFov + shift.y, -1))
        return simd_normalize(rotation * camera)
    }

    public func unfoldedUV(ndc p: SIMD2<Double>) -> SIMD2<Double> {
        // Le panorama est 2:1 : une unité de u couvre deux fois plus de pixels qu'une unité de v.
        [unfoldedCenter.x + p.x * aspect * unfoldedSpan / 4, unfoldedCenter.y - p.y * unfoldedSpan / 2]
    }

    /// Taille angulaire approximative d'un pixel écran au centre, pour choisir le niveau de mipmap.
    public func pixelAngle(viewportHeight: Double) -> Double {
        let rect = 2 * tanHalfFov / viewportHeight
        let unfolded = unfoldedSpan * .pi / viewportHeight
        return rect * (1 - morph) + unfolded * morph
    }
}

/// État de navigation des trois vues. Les gestes modifient cet état ; `parameters(aspect:)` le résout pour le rendu.
public struct ViewState: Sendable, Equatable {
    public static let fovRange: ClosedRange<Double> = (20 * .pi / 180)...(150 * .pi / 180)
    public static let unfoldedSpanRange: ClosedRange<Double> = 0.05...1.25
    private static let maxPitch = 89.9 * .pi / 180

    public var mode: ViewMode = .sphere

    // Sphère
    /// 0 = vers -Z ; positif vers +X.
    public var yaw = 0.0
    /// Positif vers le haut.
    public var pitch = 0.0
    public var roll = 0.0
    /// Champ de vision vertical.
    public var fov = 90 * Double.pi / 180
    /// Horizon verrouillé : le geste de rotation ne fait pas rouler la caméra (actif par défaut en vue sphère).
    public var horizonLocked = true

    // Fenêtre plane
    public var face: CubeFace = .front
    public var flatFov = 90 * Double.pi / 180
    public var flatShift: SIMD2<Double> = .zero

    // Dépliée
    public var unfoldedCenter: SIMD2<Double> = [0.5, 0.5]
    public var unfoldedSpan = 1.0

    /// Avancement du morphing sphère → plan (animé par l'app lors du dépliage).
    public var morph = 0.0

    public init() {}

    public static func rotation(yaw: Double, pitch: Double, roll: Double) -> simd_double3x3 {
        func ry(_ a: Double) -> simd_double3x3 {
            simd_double3x3(columns: ([cos(a), 0, -sin(a)], [0, 1, 0], [sin(a), 0, cos(a)]))
        }
        func rx(_ a: Double) -> simd_double3x3 {
            simd_double3x3(columns: ([1, 0, 0], [0, cos(a), sin(a)], [0, -sin(a), cos(a)]))
        }
        func rz(_ a: Double) -> simd_double3x3 {
            simd_double3x3(columns: ([cos(a), sin(a), 0], [-sin(a), cos(a), 0], [0, 0, 1]))
        }
        return ry(-yaw) * rx(pitch) * rz(roll)
    }

    public func parameters(aspect: Double) -> ProjectionParameters {
        let flat = mode == .flat
        return ProjectionParameters(
            rotation: flat ? Self.rotation(yaw: face.yaw, pitch: face.pitch, roll: 0) : Self.rotation(yaw: yaw, pitch: pitch, roll: roll),
            tanHalfFov: tan((flat ? flatFov : fov) / 2),
            aspect: aspect,
            shift: flat ? flatShift : .zero,
            unfoldedCenter: unfoldedCenter,
            unfoldedSpan: unfoldedSpan,
            morph: flat ? 0 : morph)
    }

    public func direction(atNDC p: SIMD2<Double>, aspect: Double) -> Vec3? {
        parameters(aspect: aspect).direction(ndc: p)
    }

    // MARK: - Gestes

    /// Glisser à deux doigts : le contenu suit les doigts. `delta` en NDC.
    public mutating func pan(byNDC delta: SIMD2<Double>, aspect: Double) {
        switch mode {
        case .sphere:
            let t = tan(fov / 2)
            yaw -= atan(delta.x * aspect * t)
            pitch = min(Self.maxPitch, max(-Self.maxPitch, pitch - atan(delta.y * t)))
        case .unfolded:
            unfoldedCenter.x -= delta.x * aspect * unfoldedSpan / 4
            unfoldedCenter.x -= floor(unfoldedCenter.x)
            unfoldedCenter.y = min(1, max(0, unfoldedCenter.y + delta.y * unfoldedSpan / 2))
        case .flat:
            let t = tan(flatFov / 2)
            flatShift -= [delta.x * aspect * t, delta.y * t]
        }
    }

    /// Pincer : `scale` > 1 rapproche.
    public mutating func zoom(by scale: Double) {
        guard scale > 0 else { return }
        switch mode {
        case .sphere: fov = Self.clamp(fov / scale, Self.fovRange)
        case .unfolded: unfoldedSpan = Self.clamp(unfoldedSpan / scale, Self.unfoldedSpanRange)
        case .flat: flatFov = Self.clamp(flatFov / scale, Self.fovRange)
        }
    }

    /// Tourner à deux doigts : roulis en vue sphère, sauf si l'horizon est verrouillé.
    public mutating func rotate(by angle: Double) {
        guard mode == .sphere, !horizonLocked else { return }
        roll += angle
    }

    /// Prépare le dépliage : la vue à plat est centrée sur la direction regardée.
    public mutating func prepareUnfold() {
        unfoldedCenter = [yaw / (2 * .pi) + 0.5 - floor(yaw / (2 * .pi) + 0.5), 0.5 - pitch / .pi]
        unfoldedSpan = 1
    }

    /// Prépare le repliage : la caméra regarde le centre de la vue à plat.
    public mutating func prepareFold() {
        yaw = (unfoldedCenter.x - 0.5) * 2 * .pi
        pitch = min(Self.maxPitch, max(-Self.maxPitch, (0.5 - unfoldedCenter.y) * .pi))
        roll = 0
    }

    public mutating func showFace(_ face: CubeFace) {
        mode = .flat
        self.face = face
        flatShift = .zero
    }

    private static func clamp(_ v: Double, _ range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, v))
    }
}
