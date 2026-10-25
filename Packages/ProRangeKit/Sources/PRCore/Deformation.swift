import simd

extension TangentFrame {
    /// Projection gnomonique (rectiligne) sur le plan tangent : les grands cercles deviennent des droites.
    /// nil pour l'hémisphère opposé.
    public func gnomonic(_ d: Vec3) -> SIMD2<Double>? {
        let z = simd_dot(d, center)
        guard z > 1e-9 else { return nil }
        return [simd_dot(d, east) / z, simd_dot(d, north) / z]
    }

    public func fromGnomonic(_ p: SIMD2<Double>) -> Vec3 {
        simd_normalize(center + east * p.x + north * p.y)
    }
}

/// Homographie du plan (3×3, h33 = 1) déterminée par quatre correspondances de points.
public struct Homography: Sendable, Equatable {
    public let matrix: simd_double3x3

    public init(matrix: simd_double3x3) {
        self.matrix = matrix
    }

    /// nil si les quatre points sont dégénérés (trois alignés…).
    public init?(from source: [SIMD2<Double>], to target: [SIMD2<Double>]) {
        guard source.count == 4, target.count == 4 else { return nil }
        // Système 8×8 : [x y 1 0 0 0 −ux −uy]·h = u, [0 0 0 x y 1 −vx −vy]·h = v.
        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let (x, y) = (source[i].x, source[i].y)
            let (u, v) = (target[i].x, target[i].y)
            a[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            a[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        // Élimination de Gauss avec pivot partiel.
        for col in 0..<8 {
            let pivot = (col..<8).max { abs(a[$0][col]) < abs(a[$1][col]) }!
            guard abs(a[pivot][col]) > 1e-12 else { return nil }
            a.swapAt(col, pivot)
            for row in 0..<8 where row != col {
                let f = a[row][col] / a[col][col]
                if f != 0 { for k in col...8 { a[row][k] -= f * a[col][k] } }
            }
        }
        let h = (0..<8).map { a[$0][8] / a[$0][$0] }
        matrix = simd_double3x3(rows: [[h[0], h[1], h[2]], [h[3], h[4], h[5]], [h[6], h[7], 1]])
    }

    public func apply(_ p: SIMD2<Double>) -> SIMD2<Double>? {
        let q = matrix * SIMD3<Double>(p.x, p.y, 1)
        guard abs(q.z) > 1e-12 else { return nil }
        return [q.x / q.z, q.y / q.z]
    }

    public var inverse: Homography { Homography(matrix: matrix.inverse) }
}

/// Distorsion par quatre coins : un quadrilatère du plan gnomonique en `origin` envoyé sur un autre.
/// Comme une image plate tenue face à soi dont on tire les coins ; les droites (grands cercles) restent droites.
public struct SphericalDistort: Sendable, Equatable {
    public let origin: Vec3
    public var sourceCorners: [SIMD2<Double>]
    public var targetCorners: [SIMD2<Double>]

    /// Carré centré sur `origin`, de demi-côté angulaire `halfAngle`.
    public init(origin: Vec3, halfAngle: Double) {
        self.origin = simd_normalize(origin)
        let s = tan(min(halfAngle, 1.2))
        sourceCorners = [[-s, s], [s, s], [s, -s], [-s, -s]]
        targetCorners = sourceCorners
    }

    public var frame: TangentFrame { TangentFrame(center: origin) }
    public var homography: Homography? { Homography(from: sourceCorners, to: targetCorners) }

    /// Directions des coins de destination (poignées à l'écran).
    public var targetDirections: [Vec3] { targetCorners.map { frame.fromGnomonic($0) } }

    public mutating func moveCorner(_ index: Int, to d: Vec3) {
        if let g = frame.gnomonic(d) { targetCorners[index] = g }
    }

    /// Direction source d'une direction de destination ; nil hors de l'hémisphère avant ou si la distorsion est dégénérée.
    public func inverse(_ d: Vec3) -> Vec3? {
        let frame = frame
        guard let g = frame.gnomonic(d), let h = homography, let s = h.inverse.apply(g) else { return nil }
        return frame.fromGnomonic(s)
    }
}

/// QuickShape : reconnaît un trait proche d'une ligne (arc de grand cercle) ou d'un cercle sur la sphère.
public enum QuickShape: Equatable, Sendable {
    case line(Vec3, Vec3)
    case circle(center: Vec3, radius: Double)

    /// Écart toléré, en fraction de la taille du trait.
    public static let tolerance = 0.12

    public static func fit(_ points: [Vec3]) -> QuickShape? {
        guard points.count >= 4, let first = points.first, let last = points.last else { return nil }
        let length = zip(points, points.dropFirst()).reduce(0) { $0 + Sphere.angle($1.0, $1.1) }
        guard length > 1e-3 else { return nil }

        // Ligne : écart maximal au grand cercle passant par les extrémités.
        let chord = Sphere.angle(first, last)
        var lineError = Double.infinity
        if chord > length * 0.5 {
            let normal = simd_normalize(simd_cross(first, last))
            lineError = points.map { abs(asin(min(1, max(-1, simd_dot($0, normal))))) }.max()! / chord
        }

        // Cercle : trait fermé, distances au centre presque constantes.
        var circle: QuickShape?
        var circleError = Double.infinity
        if chord < length * 0.25 {
            let center = simd_normalize(points.reduce(Vec3.zero, +))
            let distances = points.map { Sphere.angle(center, $0) }
            let radius = distances.reduce(0, +) / Double(distances.count)
            if radius > 1e-3 {
                circleError = distances.map { abs($0 - radius) }.max()! / radius
                circle = .circle(center: center, radius: radius)
            }
        }

        if lineError <= tolerance, lineError <= circleError { return .line(first, last) }
        if circleError <= tolerance * 2, let circle { return circle }
        return nil
    }

    /// Points de la forme, espacés d'environ `spacing` radians (pour la repeindre au pinceau).
    public func points(spacing: Double) -> [Vec3] {
        switch self {
        case let .line(a, b):
            let n = max(1, Int(Sphere.angle(a, b) / spacing))
            return (0...n).map { Sphere.slerp(a, b, Double($0) / Double(n)) }
        case let .circle(center, radius):
            let frame = TangentFrame(center: center)
            let n = max(8, Int(2 * .pi * sin(radius) / spacing))
            return (0...n).map { i in
                let angle = 2 * .pi * Double(i) / Double(n)
                return frame.unproject(SIMD2<Double>(cos(angle), sin(angle)) * radius)
            }
        }
    }
}

/// Modes de liquify.
public enum LiquifyMode: String, CaseIterable, Sendable {
    case push, twirl, pinch, expand

    public var label: String {
        switch self {
        case .push: "Pousser"
        case .twirl: "Tourbillon"
        case .pinch: "Pincer"
        case .expand: "Gonfler"
        }
    }
}
