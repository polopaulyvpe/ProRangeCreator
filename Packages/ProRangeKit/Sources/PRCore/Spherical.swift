import simd

/// Direction 3D (Y vers le haut). Toujours unitaire quand elle représente un point de la sphère.
public typealias Vec3 = SIMD3<Double>

/// Conventions équirectangulaires du projet (voir ARCHITECTURE.md) :
/// `u = atan2(x, -z) / 2π + 0.5`, `v = acos(y) / π`, v = 0 au zénith, u = 0.5 face à -Z.
public enum Equirect {
    public static func uv(from d: Vec3) -> SIMD2<Double> {
        let u = atan2(d.x, -d.z) / (2 * .pi) + 0.5
        let v = acos(min(1, max(-1, d.y))) / .pi
        return [u, v]
    }

    public static func direction(u: Double, v: Double) -> Vec3 {
        let theta = v * .pi
        let phi = (u - 0.5) * 2 * .pi
        let s = sin(theta)
        return [s * sin(phi), cos(theta), -s * cos(phi)]
    }

    /// Direction du centre du texel (x, y).
    public static func direction(x: Int, y: Int, width: Int, height: Int) -> Vec3 {
        direction(u: (Double(x) + 0.5) / Double(width), v: (Double(y) + 0.5) / Double(height))
    }

    /// Coordonnées pixel continues (le centre du texel (x, y) vaut (x + 0.5, y + 0.5)).
    public static func pixel(from d: Vec3, width: Int, height: Int) -> SIMD2<Double> {
        let p = uv(from: d)
        return [p.x * Double(width), p.y * Double(height)]
    }

    /// Latitude en radians, +π/2 au zénith.
    public static func latitude(of d: Vec3) -> Double { asin(min(1, max(-1, d.y))) }

    /// Longitude en radians dans [-π, π], 0 face à -Z, positive vers +X.
    public static func longitude(of d: Vec3) -> Double { atan2(d.x, -d.z) }

    public static func direction(latitude: Double, longitude: Double) -> Vec3 {
        direction(u: longitude / (2 * .pi) + 0.5, v: (.pi / 2 - latitude) / .pi)
    }
}

public enum Sphere {
    /// Angle entre deux directions unitaires, précis aussi pour les petits angles.
    public static func angle(_ a: Vec3, _ b: Vec3) -> Double {
        atan2(simd_length(simd_cross(a, b)), simd_dot(a, b))
    }

    /// Interpolation sphérique à vitesse angulaire constante.
    public static func slerp(_ a: Vec3, _ b: Vec3, _ t: Double) -> Vec3 {
        let omega = angle(a, b)
        let s = sin(omega)
        if s < 1e-9 { return simd_normalize(a + (b - a) * t) }
        return simd_normalize(a * (sin((1 - t) * omega) / s) + b * (sin(t * omega) / s))
    }
}

/// Repère du plan tangent en un point de la sphère, avec projection azimutale équidistante :
/// un point à l'angle α du centre, dans l'azimut β, va en (α·sin β, α·cos β), est = +x, nord local = +y.
/// Les distances au centre sont donc exactement des angles sur la sphère : un disque y est un cercle sur la sphère.
public struct TangentFrame: Sendable {
    public let center: Vec3
    public let east: Vec3
    public let north: Vec3

    public init(center: Vec3) {
        let c = simd_normalize(center)
        var e = simd_cross(c, Vec3(0, 1, 0))
        // Au pôle exact, le nord local n'est pas défini : on fixe l'est sur +X.
        e = simd_length(e) < 1e-12 ? Vec3(1, 0, 0) : simd_normalize(e)
        self.center = c
        self.east = e
        self.north = simd_cross(e, c)
    }

    /// Coordonnées (en radians) de `d` dans le plan tangent.
    public func project(_ d: Vec3) -> SIMD2<Double> {
        let cosA = simd_dot(center, d)
        let t = d - center * cosA
        let sinA = simd_length(t)
        if sinA < 1e-15 { return cosA > 0 ? .zero : [.pi, 0] }
        let k = atan2(sinA, cosA) / sinA
        return [simd_dot(t, east) * k, simd_dot(t, north) * k]
    }

    public func unproject(_ p: SIMD2<Double>) -> Vec3 {
        let alpha = simd_length(p)
        if alpha < 1e-15 { return center }
        let dir = (east * p.x + north * p.y) / alpha
        return center * cos(alpha) + dir * sin(alpha)
    }
}

/// Échantillonne les centres des dabs le long d'un trait, sur des grands cercles, à espacement angulaire constant.
public struct SphericalStrokeSampler: Sendable {
    private var last: Vec3?
    private var carry: Double = 0

    public init() {}

    public mutating func begin(at d: Vec3) -> [Vec3] {
        last = d
        carry = 0
        return [d]
    }

    /// `spacing` en radians. Renvoie les nouveaux centres de dab entre le point précédent et `d`.
    public mutating func add(_ d: Vec3, spacing: Double) -> [Vec3] {
        guard let a = last else { return begin(at: d) }
        let total = Sphere.angle(a, d)
        var out: [Vec3] = []
        var s = spacing - carry
        while s <= total {
            out.append(Sphere.slerp(a, d, s / total))
            s += spacing
        }
        carry = total - (s - spacing)
        last = d
        return out
    }
}
