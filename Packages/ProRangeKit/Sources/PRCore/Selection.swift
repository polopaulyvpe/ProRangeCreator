import simd

/// Forme de sélection tracée à l'écran, en NDC (x vers la droite, y vers le haut, dans [-1, 1]).
/// Elle est évaluée sur la sphère en projetant chaque direction dans la vue où on l'a tracée : on sélectionne ce qu'on voit.
public enum SelectionShape: Sendable, Equatable {
    case rectangle(SIMD2<Double>, SIMD2<Double>)
    case ellipse(SIMD2<Double>, SIMD2<Double>)   // deux coins du rectangle englobant
    case polygon([SIMD2<Double>])

    public func contains(_ p: SIMD2<Double>) -> Bool {
        switch self {
        case let .rectangle(a, b):
            return p.x >= min(a.x, b.x) && p.x <= max(a.x, b.x) && p.y >= min(a.y, b.y) && p.y <= max(a.y, b.y)
        case let .ellipse(a, b):
            let center = (a + b) / 2
            let radii = simd_abs(b - a) / 2
            guard radii.x > 0, radii.y > 0 else { return false }
            let q = (p - center) / radii
            return simd_dot(q, q) <= 1
        case let .polygon(points):
            guard points.count >= 3 else { return false }
            // Règle pair-impair.
            var inside = false
            var j = points.count - 1
            for i in points.indices {
                let pi = points[i], pj = points[j]
                if (pi.y > p.y) != (pj.y > p.y), p.x < (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }
    }
}

/// Comment une nouvelle forme se combine avec la sélection existante.
public enum SelectionCombine: String, CaseIterable, Sendable {
    case replace, add, subtract

    public var label: String {
        switch self {
        case .replace: "Remplacer"
        case .add: "Ajouter"
        case .subtract: "Retirer"
        }
    }

    public func combine(_ existing: Float, _ new: Float) -> Float {
        switch self {
        case .replace: new
        case .add: max(existing, new)
        case .subtract: min(existing, 1 - new)
        }
    }
}

extension ProjectionParameters {
    /// Position à l'écran (NDC) d'une direction, inverse de `direction(ndc:)`.
    /// Seulement pour une vue rectiligne (morphing 0) ou dépliée (morphing 1) ; nil derrière la caméra ou pendant le morphing.
    public func ndc(of d: Vec3) -> SIMD2<Double>? {
        if morph <= 0 {
            let c = rotation.transpose * d
            guard c.z < -1e-9 else { return nil }
            let x = c.x / -c.z - shift.x
            let y = c.y / -c.z - shift.y
            return [x / (aspect * tanHalfFov), y / tanHalfFov]
        }
        guard morph >= 0.999 else { return nil }
        let uv = Equirect.uv(from: d)
        var du = uv.x - unfoldedCenter.x
        du -= (du + 0.5).rounded(.down) // ramené dans [-0,5, 0,5)
        return [du * 4 / (aspect * unfoldedSpan), (unfoldedCenter.y - uv.y) * 2 / unfoldedSpan]
    }
}

/// Transformation d'une sélection sur la sphère : échelle (x, y) et rotation dans le plan tangent en `origin`,
/// puis déplacement (rotation de la sphère qui amène `origin` sur `target`). Exacte partout, pôles et couture compris.
public struct SphericalTransform: Sendable, Equatable {
    public var origin: Vec3
    public var target: Vec3
    /// Rotation dans le plan tangent (radians, sens trigonométrique vu de l'intérieur de la sphère).
    public var angle: Double
    public var scale: SIMD2<Double>

    public init(origin: Vec3, target: Vec3? = nil, angle: Double = 0, scale: SIMD2<Double> = [1, 1]) {
        self.origin = simd_normalize(origin)
        self.target = simd_normalize(target ?? origin)
        self.angle = angle
        self.scale = scale
    }

    public var isIdentity: Bool {
        simd_length(origin - target) < 1e-12 && abs(angle) < 1e-12 && simd_length(scale - [1, 1]) < 1e-12
    }

    public var frame: TangentFrame { TangentFrame(center: origin) }
    public var move: simd_double3x3 { Sphere.rotation(from: origin, to: target) }

    public func apply(_ d: Vec3) -> Vec3 {
        let frame = frame
        let p = frame.project(d) * scale
        let rotated = SIMD2<Double>(p.x * cos(angle) - p.y * sin(angle), p.x * sin(angle) + p.y * cos(angle))
        return move * frame.unproject(rotated)
    }

    /// Direction source d'une direction de destination (pour le mapping inverse).
    public func inverse(_ d: Vec3) -> Vec3 {
        let frame = frame
        let p = frame.project(move.transpose * d)
        let unrotated = SIMD2<Double>(p.x * cos(angle) + p.y * sin(angle), -p.x * sin(angle) + p.y * cos(angle))
        return frame.unproject(unrotated / scale)
    }
}
