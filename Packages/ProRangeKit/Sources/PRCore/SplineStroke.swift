import simd

/// Point saisi d'un trait : position (direction sur la sphère, ou point du plan avec z = 0), pression, inclinaison et
/// azimut du Pencil (direction vers laquelle il penche, dans le plan tangent : radians depuis l'est local ; nil au doigt).
public struct StrokeSample: Sendable, Equatable {
    public var point: Vec3
    public var pressure: Double
    public var tilt: Double
    public var azimuth: Double?

    public init(point: Vec3, pressure: Double, tilt: Double = 0, azimuth: Double? = nil) {
        self.point = point
        self.pressure = pressure
        self.tilt = tilt
        self.azimuth = azimuth
    }

    /// Angle interpolé par le plus court chemin.
    static func interpolatedAzimuth(_ a: Double?, _ b: Double?, _ u: Double) -> Double? {
        guard let a, let b else { return b ?? a }
        var delta = (b - a).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        return a + delta * u
    }
}

/// Pose des dabs le long d'une courbe lisse passant par les points saisis (Catmull-Rom centripète), au lieu de segments
/// droits : un trait rapide reste rond, sans angles entre deux mesures du Pencil. Pression et inclinaison sont
/// interpolées dab par dab (plus de marches d'épaisseur d'une mesure à l'autre), et l'espacement suit la pression locale.
///
/// Le segment entre deux points n'est tracé qu'à l'arrivée du point suivant (il donne la tangente) : une mesure de retard
/// (environ 4 ms avec le Pencil). `finish` trace le dernier segment au lever.
/// Sur la sphère, la courbe est calculée dans l'espace puis ramenée sur la sphère ; les distances sont des cordes
/// (égales aux angles à mieux que 10⁻⁶ près à l'échelle d'un segment).
public struct SplineStrokeSampler: Sendable {
    public let onSphere: Bool
    /// Les quatre derniers points saisis au plus.
    private var points: [StrokeSample] = []
    /// Distance déjà parcourue depuis le dernier dab.
    private var travelled = 0.0

    public init(onSphere: Bool = true) {
        self.onSphere = onSphere
    }

    /// Premier point : un dab tout de suite (le trait apparaît dès le contact).
    public mutating func begin(_ sample: StrokeSample) -> [StrokeSample] {
        points = [sample]
        travelled = 0
        return [sample]
    }

    /// Nouveau point saisi ; `spacing(pression)` donne l'écart voulu jusqu'au prochain dab. Renvoie les dabs du segment
    /// précédent, désormais complet.
    public mutating func add(_ sample: StrokeSample, spacing: (Double) -> Double) -> [StrokeSample] {
        guard let last = points.last else { return begin(sample) }
        // Point immobile : seule la pression change (on la garde pour la suite du trait).
        if simd_distance(last.point, sample.point) < 1e-9 {
            points[points.count - 1].pressure = sample.pressure
            points[points.count - 1].tilt = sample.tilt
            points[points.count - 1].azimuth = sample.azimuth
            return []
        }
        points.append(sample)
        if points.count > 4 { points.removeFirst() }
        let n = points.count
        guard n >= 3 else { return [] }
        let a = points[n - 3], b = points[n - 2]
        let before = n >= 4 ? points[n - 4].point : 2 * a.point - b.point
        return segment(a, b, before: before, after: points[n - 1].point, spacing: spacing)
    }

    /// Lever : trace le dernier segment (tangente prolongée en ligne droite).
    public mutating func finish(spacing: (Double) -> Double) -> [StrokeSample] {
        let n = points.count
        guard n >= 2 else { return [] }
        let a = points[n - 2], b = points[n - 1]
        let before = n >= 3 ? points[n - 3].point : 2 * a.point - b.point
        let out = segment(a, b, before: before, after: 2 * b.point - a.point, spacing: spacing)
        points = [b]
        return out
    }

    /// Point de la courbe de Catmull-Rom centripète (Barry-Goldman) entre `p1` et `p2`, pour u dans [0, 1].
    static func catmullRom(_ p0: Vec3, _ p1: Vec3, _ p2: Vec3, _ p3: Vec3, _ u: Double) -> Vec3 {
        func knot(_ a: Vec3, _ b: Vec3) -> Double { max(1e-12, simd_distance(a, b).squareRoot()) }
        let t0 = 0.0
        let t1 = t0 + knot(p0, p1)
        let t2 = t1 + knot(p1, p2)
        let t3 = t2 + knot(p2, p3)
        let t = t1 + (t2 - t1) * u
        let a1 = (t1 - t) / (t1 - t0) * p0 + (t - t0) / (t1 - t0) * p1
        let a2 = (t2 - t) / (t2 - t1) * p1 + (t - t1) / (t2 - t1) * p2
        let a3 = (t3 - t) / (t3 - t2) * p2 + (t - t2) / (t3 - t2) * p3
        let b1 = (t2 - t) / (t2 - t0) * a1 + (t - t0) / (t2 - t0) * a2
        let b2 = (t3 - t) / (t3 - t1) * a2 + (t - t1) / (t3 - t1) * a3
        return (t2 - t) / (t2 - t1) * b1 + (t - t1) / (t2 - t1) * b2
    }

    /// Dabs du segment a → b : la courbe est découpée finement, puis parcourue à l'espacement voulu.
    private mutating func segment(_ a: StrokeSample, _ b: StrokeSample, before: Vec3, after: Vec3,
                                  spacing: (Double) -> Double) -> [StrokeSample] {
        let chord = simd_distance(a.point, b.point)
        guard chord > 0 else { return [] }
        let minStep = max(1e-9, spacing(min(a.pressure, b.pressure)))
        // Assez de morceaux pour suivre la courbure (au moins 8) et pour placer chaque dab précisément.
        let pieces = min(256, max(8, Int(chord / minStep * 2) + 1))
        var out: [StrokeSample] = []
        var previous = a.point
        var step = spacing(a.pressure)
        for k in 1...pieces {
            let u = Double(k) / Double(pieces)
            var p = Self.catmullRom(before, a.point, b.point, after, u)
            if onSphere { p = simd_normalize(p) }
            var length = simd_distance(previous, p)
            var from = previous
            var fromU = Double(k - 1) / Double(pieces)
            // Un ou plusieurs dabs dans ce morceau.
            while travelled + length >= step {
                let f = (step - travelled) / max(length, 1e-15)
                var q = from + (p - from) * f
                if onSphere { q = simd_normalize(q) }
                let uq = fromU + (u - fromU) * f
                let sample = StrokeSample(point: q, pressure: a.pressure + (b.pressure - a.pressure) * uq,
                                          tilt: a.tilt + (b.tilt - a.tilt) * uq,
                                          azimuth: StrokeSample.interpolatedAzimuth(a.azimuth, b.azimuth, uq))
                out.append(sample)
                length -= simd_distance(from, q)
                from = q
                fromU = uq
                travelled = 0
                step = max(1e-9, spacing(sample.pressure))
            }
            travelled += length
            previous = p
        }
        return out
    }
}
