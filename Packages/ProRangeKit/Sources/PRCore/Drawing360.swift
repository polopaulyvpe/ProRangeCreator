import Foundation
import simd

// Aides au dessin propres à une toile 360 : perspective sur la sphère, peinture sur un plan, regards enregistrés.

// MARK: - Perspective

/// Trait calé sur un grand cercle (l'image d'une droite de la scène vue depuis le centre de la sphère).
public struct GreatCircleLock: Sendable, Equatable {
    public let normal: Vec3
    /// Renvoyé pour un point exactement au pôle du cercle, où la projection n'est pas définie.
    public let anchor: Vec3

    public init(normal: Vec3, anchor: Vec3) {
        self.normal = normal
        self.anchor = anchor
    }

    /// Point du grand cercle le plus proche de `d`.
    public func apply(_ d: Vec3) -> Vec3 {
        let projected: Vec3 = d - normal * simd_dot(d, normal)
        let length = simd_length(projected)
        return length > 1e-9 ? projected / length : anchor
    }
}

/// Point de fuite : toutes les droites de la scène parallèles à `direction` passent, sur la sphère, par ce point et par
/// son opposé.
public struct VanishingPoint: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var direction: Vec3
    /// Un point libre bouge seul ; les autres forment un repère rigide qui tourne d'un bloc.
    public var isFree: Bool

    public init(id: UUID = UUID(), direction: Vec3, isFree: Bool = false) {
        self.id = id
        self.direction = simd_normalize(direction)
        self.isFree = isFree
    }
}

/// Réglages de la perspective 360, enregistrés avec le projet.
public struct PerspectiveSettings: Codable, Sendable, Equatable {
    public var isEnabled = false
    public var showsGrid = true
    /// Le repère rigide tourne autour de la verticale seulement : les murs restent droits.
    public var keepsVerticals = true
    public var points: [VanishingPoint] = []

    public init() {}

    /// Repère d'une pièce ou d'une rue : trois axes perpendiculaires, orientés selon le lacet regardé.
    public static func boxPoints(yaw: Double) -> [VanishingPoint] {
        [VanishingPoint(direction: [sin(yaw), 0, -cos(yaw)]),
         VanishingPoint(direction: [cos(yaw), 0, sin(yaw)]),
         VanishingPoint(direction: [0, 1, 0])]
    }

    /// Déplace un point de fuite ; le repère rigide suit s'il en fait partie.
    public mutating func move(_ id: UUID, to direction: Vec3) {
        guard let index = points.firstIndex(where: { $0.id == id }) else { return }
        let target = simd_normalize(direction)
        let old = points[index].direction
        if points[index].isFree {
            points[index].direction = target
            return
        }
        let rotate: (Vec3) -> Vec3
        if keepsVerticals {
            // L'axe vertical ne donne aucun lacet : il reste en place.
            guard abs(old.y) < 0.98 else { return }
            let delta = atan2(target.z, target.x) - atan2(old.z, old.x)
            rotate = { SymmetrySettings.rotateAroundVertical($0, by: delta) }
        } else {
            let rotation = Sphere.rotation(from: old, to: target)
            rotate = { simd_normalize(rotation * $0) }
        }
        for i in points.indices where !points[i].isFree {
            points[i].direction = rotate(points[i].direction)
        }
    }

    /// Grand cercle du trait commencé en `start` et parti vers `d` : celui, parmi les points de fuite, qui suit le mieux
    /// le geste. Nil sans point utilisable (geste nul, ou départ exactement sur le seul point de fuite).
    public func lock(from start: Vec3, through d: Vec3) -> GreatCircleLock? {
        let rawMove: Vec3 = d - start * simd_dot(d, start)
        guard simd_length(rawMove) > 1e-9 else { return nil }
        let move = simd_normalize(rawMove)
        var bestScore = -1.0
        var bestNormal: Vec3?
        for point in points {
            let axis = simd_cross(start, point.direction)
            let s = simd_length(axis)
            guard s > 1e-3 else { continue }
            let normal = axis / s
            let tangent = simd_cross(normal, start)
            let score = abs(simd_dot(move, tangent))
            if score > bestScore {
                bestScore = score
                bestNormal = normal
            }
        }
        return bestNormal.map { GreatCircleLock(normal: $0, anchor: start) }
    }

    /// Normales de `count` grands cercles passant par `axis`, régulièrement répartis (grille affichée).
    public static func circleNormals(through axis: Vec3, count: Int) -> [Vec3] {
        let reference: Vec3 = abs(axis.y) < 0.9 ? [0, 1, 0] : [1, 0, 0]
        let e1 = simd_normalize(simd_cross(axis, reference))
        let e2 = simd_cross(axis, e1)
        return (0..<count).map { k -> Vec3 in
            let angle = Double.pi * Double(k) / Double(count)
            return e1 * cos(angle) + e2 * sin(angle)
        }
    }

    /// Points d'un grand cercle complet (le premier est répété à la fin).
    public static func circle(normal: Vec3, samples: Int) -> [Vec3] {
        let reference: Vec3 = abs(normal.y) < 0.9 ? [0, 1, 0] : [1, 0, 0]
        let e1 = simd_normalize(simd_cross(normal, reference))
        let e2 = simd_cross(normal, e1)
        return (0...samples).map { k -> Vec3 in
            let angle = 2 * Double.pi * Double(k) / Double(samples)
            return e1 * cos(angle) + e2 * sin(angle)
        }
    }
}

// MARK: - Peinture sur un plan

/// Écrasement d'un tampon dans le plan tangent : la coordonnée le long de l'axe `angle` est divisée par `ratio`.
public struct DabSquash: Sendable, Equatable {
    /// Petit axe / grand axe, dans ]0, 1].
    public var ratio: Double
    /// Direction du petit axe, en radians depuis l'est local (sens direct).
    public let angle: Double
    public let cosine: Double
    public let sine: Double

    public init(ratio: Double, angle: Double) {
        self.ratio = ratio
        self.angle = angle
        cosine = cos(angle)
        sine = sin(angle)
    }

    /// Ramène `p` (plan tangent) dans le repère du disque, et donne le facteur de la taille d'un texel en ce point
    /// (norme du gradient de la distance au centre) : le bord reste antialiasé sur un texel, même très écrasé.
    @inline(__always)
    public func unsquash(_ p: SIMD2<Double>) -> (point: SIMD2<Double>, pixelScale: Double) {
        let along: Double = (p.x * cosine + p.y * sine) / ratio
        let across: Double = -p.x * sine + p.y * cosine
        let length = (along * along + across * across).squareRoot()
        let scale: Double
        if length > 1e-12 {
            let slope: Double = along / ratio
            scale = (slope * slope + across * across).squareRoot() / length
        } else {
            scale = 1
        }
        let x: Double = along * cosine - across * sine
        let y: Double = along * sine + across * cosine
        return (SIMD2<Double>(x, y), scale)
    }
}

/// Plan de la scène sur lequel on peint (sol, plafond, mur), vu depuis le centre de la sphère.
///
/// Un tampon rond posé sur le plan apparaît, sur la sphère, comme une ellipse. Avec c = cos(angle entre la direction vue et
/// la normale du plan), il est c fois plus petit qu'au pied du plan, et encore c fois plus écrasé vers ce pied : demi-axes
/// `r·c` et `r·c²`. La distance du plan s'élimine : seule sa normale compte.
public struct PaintPlane: Sendable, Equatable {
    /// Limite près de la ligne de fuite du plan (environ 1,7°) : au-delà, le plan est à l'infini.
    public static let minimumCosine = 0.03

    /// Du centre de la sphère vers le plan (sol : vers le bas).
    public let normal: Vec3
    /// Direction d'alignement de la grille affichée.
    public let gridAxis: Vec3

    public init(normal: Vec3, gridAxis: Vec3? = nil) {
        let n = simd_normalize(normal)
        self.normal = n
        let fallback: Vec3 = abs(n.y) > 0.9 ? [1, 0, 0] : [0, 1, 0]
        let candidate = gridAxis ?? fallback
        let flat: Vec3 = candidate - n * simd_dot(candidate, n)
        self.gridAxis = simd_length(flat) > 1e-6 ? simd_normalize(flat) : simd_normalize(fallback - n * simd_dot(fallback, n))
    }

    /// `d` ramené du bon côté de la ligne de fuite : le trait longe l'horizon au lieu de passer de l'autre côté.
    public func clamped(_ d: Vec3) -> Vec3 {
        let c = simd_dot(d, normal)
        guard c < Self.minimumCosine else { return d }
        let raw: Vec3 = d - normal * c
        let length = simd_length(raw)
        let side: Vec3 = length > 1e-9 ? raw / length : gridAxis
        let height = Self.minimumCosine
        return side * (1 - height * height).squareRoot() + normal * height
    }

    /// Facteur d'espacement des tampons au point `d` : rayon de l'ellipse dans la direction du geste, pour un rayon 1.
    public func spacingScale(at d: Vec3, moving: Vec3?) -> Double {
        let c = max(Self.minimumCosine, simd_dot(d, normal))
        let major = c
        let minor = c * c
        let lowest = 0.02
        guard let moving else { return max(lowest, minor) }
        let rawMotion: Vec3 = moving - d * simd_dot(moving, d)
        let rawFoot: Vec3 = normal - d * simd_dot(normal, d)
        guard simd_length(rawMotion) > 1e-12 else { return max(lowest, minor) }
        guard simd_length(rawFoot) > 1e-9 else { return max(lowest, major) }
        let along = simd_dot(simd_normalize(rawMotion), simd_normalize(rawFoot))
        let across2 = max(0, 1 - along * along)
        let a: Double = along / minor
        let inverse = (a * a + across2 / (major * major)).squareRoot()
        return max(lowest, 1 / inverse)
    }

    /// Applique la perspective du plan de normale `normal` (celle du plan ou son image par symétrie) à un tampon.
    public static func foreshorten(_ dab: inout SphericalDab, normal: Vec3) {
        let center = simd_normalize(dab.center)
        let c = max(minimumCosine, simd_dot(center, normal))
        dab.radius = max(1e-5, dab.radius * c)
        guard c < 0.9999 else { return }
        let frame = TangentFrame(center: center)
        let foot: Vec3 = normal - center * simd_dot(normal, center)
        dab.squash = DabSquash(ratio: c, angle: atan2(simd_dot(foot, frame.north), simd_dot(foot, frame.east)))
    }

    /// Lignes d'un quadrillage du plan (pour l'affichage), en directions.
    public func gridLines(halfCount: Int = 8, samples: Int = 40) -> [[Vec3]] {
        let u = gridAxis
        let v = simd_cross(normal, u)
        let step = 0.5
        func line(offset: Vec3, running: Vec3) -> [Vec3] {
            (0...samples).map { i -> Vec3 in
                let angle: Double = (-1 + 2 * Double(i) / Double(samples)) * 1.55
                let point: Vec3 = normal + offset + running * tan(angle)
                return simd_normalize(point)
            }
        }
        var lines: [[Vec3]] = []
        for k in -halfCount...halfCount {
            let distance = Double(k) * step
            lines.append(line(offset: u * distance, running: v))
            lines.append(line(offset: v * distance, running: u))
        }
        return lines
    }
}

// MARK: - Regards

/// Direction du regard en vue sphère.
public struct ViewLook: Codable, Sendable, Equatable {
    public var yaw: Double
    public var pitch: Double
    public var roll: Double
    public var fov: Double

    public init(yaw: Double, pitch: Double, roll: Double, fov: Double) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.fov = fov
    }

    /// Écart ramené dans [-π, π].
    private static func shortest(_ delta: Double) -> Double {
        let turn = 2 * Double.pi
        return delta - (delta / turn).rounded() * turn
    }

    /// Interpolation par le plus court chemin (lacet et roulis).
    public static func interpolate(_ a: ViewLook, _ b: ViewLook, _ t: Double) -> ViewLook {
        ViewLook(yaw: a.yaw + shortest(b.yaw - a.yaw) * t,
                 pitch: a.pitch + (b.pitch - a.pitch) * t,
                 roll: a.roll + shortest(b.roll - a.roll) * t,
                 fov: a.fov + (b.fov - a.fov) * t)
    }
}

/// Regard enregistré avec le projet.
public struct ViewBookmark: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var look: ViewLook

    public init(id: UUID = UUID(), name: String, look: ViewLook) {
        self.id = id
        self.name = name
        self.look = look
    }
}
