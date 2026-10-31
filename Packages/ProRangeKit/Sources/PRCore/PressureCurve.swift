/// Courbe de réponse à la pression (Atelier > Apple Pencil), comme celles des pinceaux Procreate :
/// des points de contrôle dans [0, 1]², reliés par une cubique monotone (Fritsch-Carlson), sans dépassement.
public struct PressureCurve: Equatable, Sendable, Codable {
    /// Points triés par x ; le premier est en x = 0 et le dernier en x = 1.
    public private(set) var points: [SIMD2<Double>]
    private var tangents: [Double]

    public init(points: [SIMD2<Double>]) {
        var sorted = points.map { SIMD2(min(1, max(0, $0.x)), min(1, max(0, $0.y))) }.sorted { $0.x < $1.x }
        // Points confondus en x : on garde le dernier.
        var unique: [SIMD2<Double>] = []
        for p in sorted {
            if let last = unique.last, p.x - last.x < 1e-6 { unique[unique.count - 1] = p } else { unique.append(p) }
        }
        sorted = unique
        if sorted.first.map({ $0.x > 0 }) ?? true { sorted.insert([0, sorted.first?.y ?? 0], at: 0) }
        if sorted.last!.x < 1 { sorted.append([1, sorted.last!.y]) }
        self.points = sorted
        tangents = Self.tangents(sorted)
    }

    /// Droite de (0, 0) à (1, 1) : la pression telle quelle.
    public static let linear = PressureCurve(points: [[0, 0], [1, 1]])

    public var isLinear: Bool {
        points.count == 2 && points[0] == [0, 0] && points[1] == [1, 1]
    }

    public func value(_ x: Double) -> Double {
        let x = min(1, max(0, x))
        guard points.count > 2 else {
            let a = points[0], b = points[1]
            return a.y + (b.y - a.y) * x
        }
        var i = 0
        while i < points.count - 2 && x > points[i + 1].x { i += 1 }
        let a = points[i], b = points[i + 1]
        let h = b.x - a.x
        let t = (x - a.x) / h
        let t2 = t * t, t3 = t2 * t
        let y = (2 * t3 - 3 * t2 + 1) * a.y + (t3 - 2 * t2 + t) * h * tangents[i]
            + (-2 * t3 + 3 * t2) * b.y + (t3 - t2) * h * tangents[i + 1]
        return min(1, max(0, y))
    }

    /// Pentes de Fritsch-Carlson : la courbe reste monotone entre deux points monotones.
    private static func tangents(_ p: [SIMD2<Double>]) -> [Double] {
        let n = p.count
        let slopes = (0..<(n - 1)).map { (p[$0 + 1].y - p[$0].y) / (p[$0 + 1].x - p[$0].x) }
        var m = [Double](repeating: 0, count: n)
        m[0] = slopes[0]
        m[n - 1] = slopes[n - 2]
        if n > 2 {
            for i in 1..<(n - 1) { m[i] = slopes[i - 1] * slopes[i] <= 0 ? 0 : (slopes[i - 1] + slopes[i]) / 2 }
        }
        for i in 0..<(n - 1) {
            if slopes[i] == 0 {
                m[i] = 0
                m[i + 1] = 0
                continue
            }
            let a = m[i] / slopes[i], b = m[i + 1] / slopes[i]
            let s = a * a + b * b
            if s > 9 {
                let k = 3 / s.squareRoot()
                m[i] = k * a * slopes[i]
                m[i + 1] = k * b * slopes[i]
            }
        }
        return m
    }

    enum CodingKeys: String, CodingKey { case points }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode([[Double]].self, forKey: .points).filter { $0.count == 2 }.map { SIMD2($0[0], $0[1]) }
        self.init(points: raw.isEmpty ? [[0, 0], [1, 1]] : raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(points.map { [$0.x, $0.y] }, forKey: .points)
    }
}
