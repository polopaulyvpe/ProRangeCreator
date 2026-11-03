import simd

/// Plan dans lequel une transformation libre travaille, tangent à la sphère en son origine.
public enum TransformPlane: Int, Sendable {
    /// Projection rectiligne : les grands cercles restent droits, comme une photo tenue face à soi (contenu de moins de ~70°).
    case gnomonic
    /// Projection azimutale équidistante : couvre presque toute la sphère (calque entier, grandes sélections).
    case equidistant
}

/// Rééchantillonnage des pixels transformés.
public enum ResamplingFilter: Int, CaseIterable, Sendable {
    case nearest, bilinear, bicubic

    public var label: String {
        switch self {
        case .nearest: "Voisin le plus proche"
        case .bilinear: "Bilinéaire"
        case .bicubic: "Bicubique"
        }
    }
}

/// Carreau de Bézier bicubique du carré unité dans lui-même : la déformation par maillage (mode Déformer).
/// Points de contrôle `points[j * 4 + i]`, i le long de u (vers la droite), j le long de v (vers le bas).
/// Hors du carré, le déplacement du bord le plus proche est prolongé : la fonction reste continue partout.
public struct WarpMesh: Sendable, Equatable {
    public var points: [SIMD2<Double>]

    public static let identity = WarpMesh(points: (0..<16).map { SIMD2<Double>(Double($0 % 4) / 3, Double($0 / 4) / 3) })

    public init(points: [SIMD2<Double>]) {
        precondition(points.count == 16)
        self.points = points
    }

    public var isIdentity: Bool {
        zip(points, Self.identity.points).allSatisfy { simd_distance($0, $1) < 1e-12 }
    }

    static func bernstein(_ t: Double) -> SIMD4<Double> {
        let s = 1 - t
        return [s * s * s, 3 * t * s * s, 3 * t * t * s, t * t * t]
    }

    static func bernsteinDerivative(_ t: Double) -> SIMD4<Double> {
        let s = 1 - t
        return [-3 * s * s, 3 * s * s - 6 * t * s, 6 * t * s - 3 * t * t, 3 * t * t]
    }

    /// Point du carreau et ses dérivées partielles, en (u, v) pris dans [0, 1].
    func patch(_ w: SIMD2<Double>) -> (value: SIMD2<Double>, du: SIMD2<Double>, dv: SIMD2<Double>) {
        let bu = Self.bernstein(w.x), bv = Self.bernstein(w.y)
        let du = Self.bernsteinDerivative(w.x), dv = Self.bernsteinDerivative(w.y)
        var value = SIMD2<Double>.zero, gu = SIMD2<Double>.zero, gv = SIMD2<Double>.zero
        for j in 0..<4 {
            for i in 0..<4 {
                let p = points[j * 4 + i]
                value += p * (bu[i] * bv[j])
                gu += p * (du[i] * bv[j])
                gv += p * (bu[i] * dv[j])
            }
        }
        return (value, gu, gv)
    }

    /// Image de `w` (prolongée hors du carré) et jacobienne (colonnes ∂/∂u, ∂/∂v).
    func evaluateWithJacobian(_ w: SIMD2<Double>) -> (value: SIMD2<Double>, du: SIMD2<Double>, dv: SIMD2<Double>) {
        let c = simd_clamp(w, .zero, .one)
        let p = patch(c)
        let insideU = w.x >= 0 && w.x <= 1, insideV = w.y >= 0 && w.y <= 1
        // M(w) = w + D(clamp(w)), D(c) = B(c) − c : sur une coordonnée bornée, la dérivée de D est nulle.
        let du: SIMD2<Double> = insideU ? p.du : [1, 0]
        let dv: SIMD2<Double> = insideV ? p.dv : [0, 1]
        return (w + p.value - c, du, dv)
    }

    public func evaluate(_ w: SIMD2<Double>) -> SIMD2<Double> {
        evaluateWithJacobian(w).value
    }

    /// Antécédent de `m` par la méthode de Newton, en partant de `m` lui-même (même calcul que le shader).
    public func inverse(_ m: SIMD2<Double>) -> SIMD2<Double>? {
        var w = m
        for _ in 0..<Self.newtonSteps {
            let e = evaluateWithJacobian(w)
            let r = e.value - m
            if simd_length(r) < 1e-9 { return w }
            let det = e.du.x * e.dv.y - e.dv.x * e.du.y
            guard abs(det) > 1e-12 else { return nil }
            var step = SIMD2<Double>(e.dv.y * r.x - e.dv.x * r.y, -e.du.y * r.x + e.du.x * r.y) / det
            let length = simd_length(step)
            if length > 0.5 { step *= 0.5 / length }
            w -= step
        }
        return simd_length(evaluate(w) - m) < 1e-4 ? w : nil
    }

    public static let newtonSteps = 16

    /// Tire le carreau en `w` (dans le carré) de `delta` : chaque point de contrôle bouge selon son poids en `w`,
    /// au minimum de déplacement total ; le point du carreau sous le doigt suit exactement.
    public mutating func drag(at w: SIMD2<Double>, by delta: SIMD2<Double>) {
        let c = simd_clamp(w, .zero, .one)
        let bu = Self.bernstein(c.x), bv = Self.bernstein(c.y)
        var sum = 0.0
        for j in 0..<4 { for i in 0..<4 { sum += bu[i] * bv[j] * bu[i] * bv[j] } }
        guard sum > 1e-12 else { return }
        for j in 0..<4 {
            for i in 0..<4 { points[j * 4 + i] += delta * (bu[i] * bv[j] / sum) }
        }
    }

    /// Le même carreau vu dans un miroir vertical (gauche ↔ droite) ou horizontal (haut ↔ bas).
    public func mirrored(horizontally: Bool) -> WarpMesh {
        var out = points
        for j in 0..<4 {
            for i in 0..<4 {
                let p = horizontally ? points[j * 4 + (3 - i)] : points[(3 - j) * 4 + i]
                out[j * 4 + i] = horizontally ? [1 - p.x, p.y] : [p.x, 1 - p.y]
            }
        }
        return WarpMesh(points: out)
    }
}

/// Transformation libre d'un contenu sur la sphère, comme l'outil Transformer d'une app de dessin à plat :
/// - le contenu est vu dans un plan tangent en `origin` (`plane`) ;
/// - sa boîte de départ (`sourceOrigin`, `sourceX`, `sourceY` : coin haut gauche et côtés, carré unité → plan) ;
/// - est envoyée sur un quadrilatère (`corners`, haut gauche, haut droit, bas droit, bas gauche) par une homographie,
///   après la déformation `mesh` du carré unité ;
/// - puis déplacée sur la sphère par la rotation qui amène `origin` sur `target`.
/// Libre et Uniforme modifient les coins par des affinités, Déformation les tire un par un, Déformer tire le maillage.
public struct FreeTransform: Sendable, Equatable {
    public var origin: Vec3
    public var target: Vec3
    public var plane: TransformPlane
    public var sourceOrigin: SIMD2<Double>
    public var sourceX: SIMD2<Double>
    public var sourceY: SIMD2<Double>
    public var corners: [SIMD2<Double>]
    public var mesh: WarpMesh

    public static let unitCorners: [SIMD2<Double>] = [[0, 0], [1, 0], [1, 1], [0, 1]]

    /// Boîte alignée sur l'est et le nord du plan en `origin` : x dans `minX...maxX`, y dans `minY...maxY`.
    public init(origin: Vec3, plane: TransformPlane, minX: Double, maxX: Double, minY: Double, maxY: Double) {
        self.origin = simd_normalize(origin)
        self.target = self.origin
        self.plane = plane
        sourceOrigin = [minX, maxY]
        sourceX = [maxX - minX, 0]
        sourceY = [0, minY - maxY]
        corners = []
        mesh = .identity
        corners = sourceCorners
    }

    /// Ancienne transformation (déplacement, échelle, rotation dans le plan équidistant).
    public init(_ t: SphericalTransform) {
        self.init(origin: t.origin, plane: .equidistant, minX: -1, maxX: 1, minY: -1, maxY: 1)
        target = t.target
        corners = corners.map { p in
            let s = p * t.scale
            return [s.x * cos(t.angle) - s.y * sin(t.angle), s.x * sin(t.angle) + s.y * cos(t.angle)]
        }
    }

    /// Ancienne distorsion par quatre coins (plan gnomonique).
    public init(_ d: SphericalDistort) {
        let s = d.sourceCorners
        self.init(origin: d.origin, plane: .gnomonic, minX: s[0].x, maxX: s[1].x, minY: s[2].y, maxY: s[0].y)
        corners = d.targetCorners
    }

    /// Boîte qui contient les directions `samples` (contenu ou sélection), dans le repère de leur direction moyenne.
    /// Plan rectiligne si tout tient à moins de ~70° du centre, équidistant sinon ; nil sans échantillon.
    public static func fitting(_ samples: [Vec3]) -> FreeTransform? {
        guard !samples.isEmpty else { return nil }
        let sum = samples.reduce(Vec3.zero, +)
        let center = simd_length(sum) > 1e-9 ? simd_normalize(sum) : samples[0]
        let radius = samples.map { Sphere.angle(center, $0) }.max() ?? 0
        let plane: TransformPlane = radius < 1.2 ? .gnomonic : .equidistant
        let t = FreeTransform(origin: center, plane: plane, minX: 0, maxX: 1, minY: 0, maxY: 1)
        var lo = SIMD2<Double>(repeating: .infinity), hi = SIMD2<Double>(repeating: -.infinity)
        for d in samples {
            guard let p = t.toPlane(d) else { continue }
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        guard lo.x.isFinite, hi.x.isFinite else { return nil }
        let pad = (hi - lo) * 0.01 + 0.002
        lo -= pad
        hi += pad
        return FreeTransform(origin: center, plane: plane, minX: lo.x, maxX: hi.x, minY: lo.y, maxY: hi.y)
    }

    // MARK: - Plan et sphère

    public var frame: TangentFrame { TangentFrame(center: origin) }
    public var move: simd_double3x3 { Sphere.rotation(from: origin, to: target) }

    /// Coordonnées d'une direction (non déplacée) dans le plan ; nil derrière le plan rectiligne.
    public func toPlane(_ d: Vec3) -> SIMD2<Double>? {
        switch plane {
        case .gnomonic: frame.gnomonic(d)
        case .equidistant: frame.project(d)
        }
    }

    public func fromPlane(_ p: SIMD2<Double>) -> Vec3 {
        switch plane {
        case .gnomonic: frame.fromGnomonic(p)
        case .equidistant: frame.unproject(p)
        }
    }

    /// Point du plan sous une direction de la toile (le doigt), déplacement retiré.
    public func planePoint(under d: Vec3) -> SIMD2<Double>? {
        toPlane(move.transpose * d)
    }

    /// Direction de la toile d'un point du plan (déplacement compris).
    public func direction(ofPlanePoint p: SIMD2<Double>) -> Vec3 {
        move * fromPlane(p)
    }

    public func source(_ w: SIMD2<Double>) -> SIMD2<Double> { sourceOrigin + sourceX * w.x + sourceY * w.y }
    public var sourceCorners: [SIMD2<Double>] { Self.unitCorners.map(source) }
    public var homography: Homography? { Homography(from: Self.unitCorners, to: corners) }

    /// Point du plan où arrive le point `w` de la boîte (carré unité), maillage compris.
    public func targetPoint(_ w: SIMD2<Double>) -> SIMD2<Double>? {
        homography?.apply(mesh.evaluate(w))
    }

    public var isIdentity: Bool {
        Sphere.angle(origin, target) < 1e-12 && mesh.isIdentity
            && zip(corners, sourceCorners).allSatisfy { simd_distance($0, $1) < 1e-12 }
    }

    /// Centre du quadrilatère (moyenne des coins).
    public var center: SIMD2<Double> { corners.reduce(.zero, +) / 4 }

    // MARK: - Calcul

    /// Matrices précalculées : à utiliser dans les boucles par pixel.
    public struct Resolved: Sendable {
        public let transform: FreeTransform
        public let frame: TangentFrame
        public let move: simd_double3x3
        public let homography: simd_double3x3
        public let inverseHomography: simd_double3x3
        /// Signe de la coordonnée homogène au centre : de l'autre côté, la droite de fuite est franchie.
        public let sign: Double
        public let meshIsIdentity: Bool

        public func toPlane(_ d: Vec3) -> SIMD2<Double>? {
            switch transform.plane {
            case .gnomonic: frame.gnomonic(d)
            case .equidistant: frame.project(d)
            }
        }

        public func fromPlane(_ p: SIMD2<Double>) -> Vec3 {
            switch transform.plane {
            case .gnomonic: frame.fromGnomonic(p)
            case .equidistant: frame.unproject(p)
            }
        }

        /// Direction de destination d'une direction source.
        public func apply(_ d: Vec3) -> Vec3? {
            guard let p = toPlane(d) else { return nil }
            let t = transform
            // Inverse de l'affinité de la boîte (carré unité → plan).
            let det = t.sourceX.x * t.sourceY.y - t.sourceY.x * t.sourceX.y
            guard abs(det) > 1e-15 else { return nil }
            let r = p - t.sourceOrigin
            let w = SIMD2<Double>(t.sourceY.y * r.x - t.sourceY.x * r.y, -t.sourceX.y * r.x + t.sourceX.x * r.y) / det
            let m = meshIsIdentity ? w : t.mesh.evaluate(w)
            let h = homography * SIMD3<Double>(m.x, m.y, 1)
            guard h.z * sign > 1e-12 else { return nil }
            return move * fromPlane([h.x / h.z, h.y / h.z])
        }

        /// Direction source d'une direction de destination (mapping inverse ; même calcul que le shader).
        public func inverse(_ d: Vec3) -> Vec3? {
            guard let q = toPlane(move.transpose * d) else { return nil }
            let h = inverseHomography * SIMD3<Double>(q.x, q.y, 1)
            guard h.z * sign > 1e-12 else { return nil }
            let m = SIMD2<Double>(h.x / h.z, h.y / h.z)
            guard let w = meshIsIdentity ? m : transform.mesh.inverse(m) else { return nil }
            return fromPlane(transform.source(w))
        }
    }

    public func resolved() -> Resolved? {
        guard let h = homography else { return nil }
        let inv = h.matrix.inverse
        let c = inv * SIMD3<Double>(center.x, center.y, 1)
        return Resolved(transform: self, frame: frame, move: move, homography: h.matrix, inverseHomography: inv,
                        sign: c.z >= 0 ? 1 : -1, meshIsIdentity: mesh.isIdentity)
    }

    public func inverse(_ d: Vec3) -> Vec3? { resolved()?.inverse(d) }
    public func apply(_ d: Vec3) -> Vec3? { resolved()?.apply(d) }

    // MARK: - Édition

    /// Applique une affinité du plan aux coins (le maillage suit : il est défini dans la boîte).
    public mutating func applyAffine(_ f: (SIMD2<Double>) -> SIMD2<Double>) {
        let moved = corners.map(f)
        guard Homography(from: Self.unitCorners, to: moved) != nil else { return }
        corners = moved
    }

    /// Rotation des coins de `angle` (radians, sens trigonométrique du plan) autour de `pivot` (le centre par défaut).
    public mutating func rotate(by angle: Double, around pivot: SIMD2<Double>? = nil) {
        let c = pivot ?? center
        let (cs, sn) = (cos(angle), sin(angle))
        applyAffine { p in
            let r = p - c
            return c + SIMD2<Double>(r.x * cs - r.y * sn, r.x * sn + r.y * cs)
        }
    }

    /// Axes locaux de la boîte transformée (gauche → droite, haut → bas), en moyenne sur les côtés opposés.
    public var axes: (x: SIMD2<Double>, y: SIMD2<Double>) {
        ((corners[1] - corners[0] + corners[2] - corners[3]) / 2, (corners[3] - corners[0] + corners[2] - corners[1]) / 2)
    }

    /// Mise à l'échelle par une poignée : le coin `handle` (0…3) ou le milieu de côté `handle` (4 haut, 5 droit,
    /// 6 bas, 7 gauche) suit `point` ; le côté ou le coin opposé reste en place. `uniform` garde les proportions.
    public mutating func scale(handle: Int, to point: SIMD2<Double>, from start: SIMD2<Double>, initial: FreeTransform,
                               uniform: Bool) {
        var base = initial
        let (ax, ay) = initial.axes
        let det = ax.x * ay.y - ay.x * ax.y
        guard abs(det) > 1e-15 else { return }
        // Coordonnées locales (dans la base des axes) d'un vecteur du plan.
        func local(_ v: SIMD2<Double>) -> SIMD2<Double> { [(ay.y * v.x - ay.x * v.y) / det, (-ax.y * v.x + ax.x * v.y) / det] }
        let anchor: SIMD2<Double>
        let signs: SIMD2<Double>
        switch handle {
        case 0: anchor = initial.corners[2]; signs = [-1, -1]
        case 1: anchor = initial.corners[3]; signs = [1, -1]
        case 2: anchor = initial.corners[0]; signs = [1, 1]
        case 3: anchor = initial.corners[1]; signs = [-1, 1]
        case 4: anchor = (initial.corners[2] + initial.corners[3]) / 2; signs = [0, -1]
        case 5: anchor = (initial.corners[0] + initial.corners[3]) / 2; signs = [1, 0]
        case 6: anchor = (initial.corners[0] + initial.corners[1]) / 2; signs = [0, 1]
        default: anchor = (initial.corners[1] + initial.corners[2]) / 2; signs = [-1, 0]
        }
        let grabbed = local(start - anchor)
        let now = local(point - anchor)
        var s = SIMD2<Double>(1, 1)
        if signs.x != 0, abs(grabbed.x) > 1e-12 { s.x = now.x / grabbed.x }
        if signs.y != 0, abs(grabbed.y) > 1e-12 { s.y = now.y / grabbed.y }
        if uniform {
            // Coin : moyenne des deux axes ; milieu de côté : l'axe tiré entraîne l'autre.
            let k = signs.x != 0 && signs.y != 0 ? (s.x + s.y) / 2 : (signs.x != 0 ? s.x : s.y)
            s = [k, k]
        }
        base.applyAffine { p in
            let l = local(p - anchor) * s
            return anchor + ax * l.x + ay * l.y
        }
        self = base
    }

    /// Déformation : un coin suit le doigt.
    public mutating func moveCorner(_ index: Int, to point: SIMD2<Double>) {
        var moved = corners
        moved[index] = point
        guard Homography(from: Self.unitCorners, to: moved) != nil else { return }
        corners = moved
    }

    /// Déformation : un côté (0 haut, 1 droit, 2 bas, 3 gauche) se décale de `delta` (ses deux coins ensemble).
    public mutating func moveEdge(_ edge: Int, by delta: SIMD2<Double>) {
        var moved = corners
        moved[edge] += delta
        moved[(edge + 1) % 4] += delta
        guard Homography(from: Self.unitCorners, to: moved) != nil else { return }
        corners = moved
    }

    /// Point du carré unité (avant maillage) sous un point du plan : ce qu'on attrape pour tirer le maillage.
    public func boxPoint(under p: SIMD2<Double>) -> SIMD2<Double>? {
        guard let h = homography, let m = h.inverse.apply(p) else { return nil }
        return mesh.inverse(m)
    }

    /// Déformer : le point `w` de la boîte (attrapé au début du geste) suit le point du plan `p`.
    public mutating func warp(grabbed w: SIMD2<Double>, to p: SIMD2<Double>) {
        guard let h = homography, let m = h.inverse.apply(p) else { return }
        mesh.drag(at: w, by: m - mesh.evaluate(simd_clamp(w, .zero, .one)))
    }

    /// Retourne le contenu dans sa boîte : gauche ↔ droite (`horizontally`) ou haut ↔ bas.
    public mutating func flip(horizontally: Bool) {
        corners = horizontally ? [corners[1], corners[0], corners[3], corners[2]] : [corners[3], corners[2], corners[1], corners[0]]
        mesh = mesh.mirrored(horizontally: horizontally)
    }

    /// Tourne la boîte seule, sans le contenu (poignée de réglage de la boîte) ; sans maillage seulement.
    public mutating func rotateBox(by angle: Double) {
        guard mesh.isIdentity, let map = Homography(from: sourceCorners, to: corners) else { return }
        let c = source([0.5, 0.5])
        let (cs, sn) = (cos(angle), sin(angle))
        func turn(_ v: SIMD2<Double>) -> SIMD2<Double> { [v.x * cs - v.y * sn, v.x * sn + v.y * cs] }
        let newOrigin = c + turn(sourceOrigin - c)
        let newX = turn(sourceX), newY = turn(sourceY)
        var next = self
        next.sourceOrigin = newOrigin
        next.sourceX = newX
        next.sourceY = newY
        let mapped = next.sourceCorners.compactMap { map.apply($0) }
        guard mapped.count == 4, Homography(from: Self.unitCorners, to: mapped) != nil else { return }
        next.corners = mapped
        self = next
    }

    /// Rétablir : le contenu revient à sa place et à sa forme d'origine.
    public mutating func reset() {
        target = origin
        mesh = .identity
        corners = sourceCorners
    }
}
