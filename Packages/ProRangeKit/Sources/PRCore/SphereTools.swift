import simd

/// Symétrie de dessin sur la sphère : chaque dab est recopié par des miroirs (plans passant par le centre)
/// et/ou des rotations autour de l'axe vertical.
public struct SymmetrySettings: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case none
        /// Miroir gauche / droite : plan vertical contenant l'axe de la vue.
        case mirrorVertical
        /// Miroir haut / bas : plan de l'horizon.
        case mirrorHorizon
        /// Les deux miroirs (quatre copies).
        case quadrant
        /// `count` copies tournées autour de la verticale.
        case radial
        /// Radiale + miroir vertical (kaléidoscope).
        case kaleidoscope

        public var label: String {
            switch self {
            case .none: "Aucune"
            case .mirrorVertical: "Miroir gauche/droite"
            case .mirrorHorizon: "Miroir haut/bas"
            case .quadrant: "Quadrants"
            case .radial: "Radiale"
            case .kaleidoscope: "Kaléidoscope"
            }
        }
    }

    public var kind: Kind
    /// Nombre de copies en radiale.
    public var count: Int
    /// Lacet de l'axe de symétrie (direction regardée quand on l'a activée).
    public var axisYaw: Double

    public init(kind: Kind = .none, count: Int = 6, axisYaw: Double = 0) {
        self.kind = kind
        self.count = max(2, count)
        self.axisYaw = axisYaw
    }

    /// Normale du plan miroir vertical : perpendiculaire à l'axe de la vue, horizontale.
    private var verticalMirrorNormal: Vec3 { [cos(axisYaw), 0, sin(axisYaw)] }

    public static func mirror(_ d: Vec3, normal n: Vec3) -> Vec3 { d - 2 * simd_dot(d, n) * n }

    public static func rotateAroundVertical(_ d: Vec3, by angle: Double) -> Vec3 {
        [d.x * cos(angle) - d.z * sin(angle), d.y, d.x * sin(angle) + d.z * cos(angle)]
    }

    /// Toutes les copies de `d`, `d` compris en premier.
    public func images(of d: Vec3) -> [Vec3] {
        let horizon = Vec3(0, 1, 0)
        switch kind {
        case .none:
            return [d]
        case .mirrorVertical:
            return [d, Self.mirror(d, normal: verticalMirrorNormal)]
        case .mirrorHorizon:
            return [d, Self.mirror(d, normal: horizon)]
        case .quadrant:
            let m = Self.mirror(d, normal: verticalMirrorNormal)
            return [d, m, Self.mirror(d, normal: horizon), Self.mirror(m, normal: horizon)]
        case .radial:
            return (0..<count).map { Self.rotateAroundVertical(d, by: 2 * .pi * Double($0) / Double(count)) }
        case .kaleidoscope:
            let m = Self.mirror(d, normal: verticalMirrorNormal)
            return (0..<count).flatMap { k -> [Vec3] in
                let angle = 2 * .pi * Double(k) / Double(count)
                return [Self.rotateAroundVertical(d, by: angle), Self.rotateAroundVertical(m, by: angle)]
            }
        }
    }
}

/// Dégradé défini sur la sphère par deux directions.
public struct SphericalGradient: Sendable {
    public enum Shape: String, CaseIterable, Sendable {
        /// Le long du grand cercle de A vers B (bandes perpendiculaires à ce grand cercle).
        case linear
        /// Distance angulaire à A, rayon = angle(A, B).
        case radial

        public var label: String { self == .linear ? "Linéaire" : "Radial" }
    }

    public let shape: Shape
    public let start: Vec3
    public let end: Vec3
    private let span: Double
    private let tangent: Vec3

    public init(shape: Shape, start: Vec3, end: Vec3) {
        self.shape = shape
        self.start = simd_normalize(start)
        self.end = simd_normalize(end)
        span = max(Sphere.angle(self.start, self.end), 1e-6)
        let t = self.end - self.start * simd_dot(self.start, self.end)
        tangent = simd_length(t) > 1e-12 ? simd_normalize(t) : Vec3(1, 0, 0)
    }

    /// Position dans [0, 1] du dégradé pour une direction.
    public func parameter(at d: Vec3) -> Double {
        switch shape {
        case .radial:
            return min(1, Sphere.angle(start, d) / span)
        case .linear:
            // Angle signé le long du grand cercle A→B, mesuré depuis A.
            let along = atan2(simd_dot(d, tangent), simd_dot(d, start))
            return min(1, max(0, along / span))
        }
    }
}

extension Sphere {
    /// Rotation minimale qui amène `from` sur `to`.
    public static func rotation(from: Vec3, to: Vec3) -> simd_double3x3 {
        let a = simd_normalize(from)
        let b = simd_normalize(to)
        let axis = simd_cross(a, b)
        let s = simd_length(axis)
        let c = simd_dot(a, b)
        if s < 1e-12 {
            if c > 0 { return matrix_identity_double3x3 }
            // Demi-tour autour d'un axe perpendiculaire quelconque.
            let perp = abs(a.x) < 0.9 ? simd_normalize(simd_cross(a, [1, 0, 0])) : simd_normalize(simd_cross(a, [0, 1, 0]))
            return simd_double3x3(simd_quatd(angle: .pi, axis: perp))
        }
        return simd_double3x3(simd_quatd(angle: atan2(s, c), axis: axis / s))
    }
}
