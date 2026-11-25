import Foundation
import simd

/// Lissage du tracé, appliqué aux points de l'écran avant la projection. Porté du moteur de ProCraft
/// (github.com/artcraft-android/procraft, `crates/engine/src/stroke.rs`, MIT ou Apache-2.0, voir NOTICE.md), en quatre
/// étages, dans l'ordre :
/// 1. **Filtrage du mouvement** : passe-bas à phase nulle (fenêtre de Blackman-Harris, seule l'amplitude de chaque fréquence
///    est gardée) : les tremblements rapides disparaissent sans que le trait ne traîne ni ne coupe les courbes ;
/// 2. **StreamLine** : le trait suit la main avec un retard élastique ; les 50 dernières millisecondes restent en attente
///    et, au lever, le trait les rejoint en se recourbant vers la mine ;
/// 3. **Stabilisation** : moyenne de chaque point avec ceux de part et d'autre (jusqu'à 120 échantillons de chaque côté) ;
/// 4. **Lissage de la pression**, avec le StreamLine.
///
/// Tout est réglé pour un rythme de référence (240 mesures par seconde au Pencil, 120 au doigt) et compte le temps réel
/// écoulé : le lissage est le même quel que soit le rythme des mesures. Les points sont rééchantillonnés à ce rythme avant
/// les moyennes. Au-delà des extrémités, le trait est prolongé par symétrie centrale : la moyenne commence et finit
/// exactement sur ses extrémités. Les étages symétriques attendent les points suivants : ils ajoutent un délai.
public struct StrokeStabilizer: Sendable {
    public struct Settings: Sendable, Equatable {
        public var streamLine: Double
        public var stabilization: Double
        public var motionFiltering: Double
        public var pressureSmoothing: Double

        public init(streamLine: Double = 0, stabilization: Double = 0, motionFiltering: Double = 0, pressureSmoothing: Double = 0) {
            self.streamLine = streamLine
            self.stabilization = stabilization
            self.motionFiltering = motionFiltering
            self.pressureSmoothing = pressureSmoothing
        }

        public var isActive: Bool { streamLine > 0 || stabilization > 0 || motionFiltering > 0 || pressureSmoothing > 0 }
    }

    public typealias Output = (point: SIMD2<Double>, pressure: Double)

    // Réglages mesurés par ProCraft.
    static let penRate = 240.0
    static let fingerRate = 120.0
    /// Mesures plus rapprochées que ça (secondes) : arrivées en paquet, comptées pour un échantillon chacune.
    static let batched = 0.0005
    static let mostSteps = 24.0
    static let streamWindow = 0.050
    static let mostAveraged = 120.0
    static let stabilizationPower = 2.2

    /// Part de la position précédente gardée à chaque échantillon de référence, pour un StreamLine `amount`.
    static func streamlineKeep(_ amount: Double) -> Double { 0.96 * pow(min(1, max(0, amount)), 0.125) }
    static func pressureKeep(_ amount: Double) -> Double { 0.999 * pow(min(1, max(0, amount)), 0.0625) }

    /// Poids du filtrage du mouvement pour un point et ceux de part et d'autre (nombre impair, somme 1), à `rate` mesures
    /// par seconde. Passe-bas fenêtré (Blackman-Harris) dont on ne garde que l'amplitude de la réponse : filtre à phase
    /// nulle, symétrique. `expression` allonge le filtre (coupure plus franche).
    public static func motionWeights(amount: Double, expression: Double = 0, rate: Double) -> [Double] {
        let a = min(1, max(0, amount))
        guard a > 0 else { return [] }
        let strength = pow(a, 0.01)
        let cut = rate * (1 - strength) + (1.0 / 16.0) * strength
        let longer = 1 + 7 * min(1, max(0, expression))
        let wanted = rate / cut * longer
        var size = 2
        while Double(size) < wanted.rounded(.up), size < 1024 { size *= 2 }
        let span = min(wanted, Double(size - 1))
        let band = 2 * cut / rate
        let taps = Int(span)
        let filter: [Double] = (0..<taps).map { i -> Double in
            let x = (Double(i) + 1 - span / 2) * band * .pi
            let sinc = x == 0 ? 1 : sin(x) / x
            let t = 2 * Double.pi * Double(i) / span
            let window = 0.35875 - 0.48829 * cos(t) + 0.14128 * cos(2 * t) - 0.01168 * cos(3 * t)
            return band * sinc * window
        }
        let half = size / 2
        // Amplitude de la réponse en fréquence, puis retour aux échantillons (transformée en cosinus).
        let through: [Double] = (0...half).map { k -> Double in
            var re = 0.0, im = 0.0
            for (n, h) in filter.enumerated() {
                let angle = 2 * Double.pi * Double((k * n) % size) / Double(size)
                re += h * cos(angle)
                im += h * sin(angle)
            }
            return (re * re + im * im).squareRoot()
        }
        let side: [Double] = (0...half).map { j -> Double in
            var sum = 0.0
            for (k, value) in through.enumerated() {
                let angle = 2 * Double.pi * Double((j * k) % size) / Double(size)
                sum += value * cos(angle) * (k == 0 || k == half ? 1 : 2)
            }
            return sum
        }
        let least = abs(side[0]) * 1e-5
        let reach = side.lastIndex { abs($0) > least } ?? 0
        let all = Array(side[0...reach].reversed()) + Array(side[1..<(reach + 1)])
        let total = all.reduce(0, +)
        return all.map { $0 / total }
    }

    /// Points rééchantillonnés à un échantillon de référence d'écart (x, y, pression), prolongés par symétrie centrale.
    struct Resampled: Sendable {
        var points: [SIMD3<Double>] = []
        var input: SIMD3<Double>?
        var past = 0.0
        /// Points déjà moyennés et sortis.
        var settled = 0

        var count: Int { points.count }

        mutating func add(_ to: SIMD3<Double>, steps: Double) {
            guard let from = input else {
                input = to
                points.append(to)
                return
            }
            input = to
            var next = 1 - past
            while next <= steps {
                points.append(from + (to - from) * (next / steps))
                next += 1
            }
            past = steps - (next - 1)
        }

        /// Fin de l'entrée : la dernière position compte comme dernier point.
        mutating func close() {
            if past > 1e-3, let input {
                points.append(input)
                past = 0
            }
        }

        func lane(_ i: Int) -> SIMD3<Double> {
            let last = points.count - 1
            guard last > 0 else { return points[0] }
            if i < 0 { return 2 * points[0] - points[min(-i, last)] }
            if i > last { return 2 * points[last] - points[max(2 * last - i, 0)] }
            return points[i]
        }
    }

    public let settings: Settings
    private let rate: Double
    private let motion: [Double]
    private let stableHalf: Int
    private var filtering = Resampled()
    private var stable = Resampled()
    /// Fenêtre du StreamLine : points pas encore suivis, avec le temps écoulé depuis le précédent (secondes).
    private var window: [(point: SIMD3<Double>, dt: Double)] = []
    private var smoothed: SIMD3<Double>?
    private var lastTime: Double?
    private var first: SIMD3<Double>?
    private var moved = false
    /// Le premier point sorti est le premier point du trait, déjà rendu par `begin`.
    private var skipFirst = true

    public init(settings: Settings, pen: Bool = true) {
        self.settings = settings
        rate = pen ? Self.penRate : Self.fingerRate
        motion = Self.motionWeights(amount: settings.motionFiltering, rate: rate)
        stableHalf = Int(pow(min(1, max(0, settings.stabilization)), Self.stabilizationPower) * Self.mostAveraged)
    }

    private var interval: Double { 1 / rate }
    private var motionHalf: Int { motion.count / 2 }
    private var streams: Bool { settings.streamLine > 0 || settings.pressureSmoothing > 0 }

    /// Premier point du trait : rendu tel quel (toutes les moyennes commencent exactement sur lui).
    public mutating func begin(_ point: SIMD2<Double>, pressure: Double, time: Double) -> Output {
        _ = add(point, pressure: pressure, time: time)
        return (point, pressure)
    }

    /// Point brut du trait au temps `time` (secondes) : renvoie les points lissés désormais connus (aucun, un ou plusieurs).
    public mutating func add(_ point: SIMD2<Double>, pressure: Double, time: Double) -> [Output] {
        let target = SIMD3<Double>(point.x, point.y, pressure)
        if let first, simd_distance(SIMD2(first.x, first.y), point) > 1e-12 { moved = true }
        if first == nil { first = target }
        let since = lastTime.map { abs(time - $0) } ?? 0
        let steps = lastTime == nil || since < Self.batched ? 1 : min(Self.mostSteps, since / interval)
        lastTime = time
        var out: [SIMD3<Double>] = []
        if motionHalf > 0 {
            filtering.add(target, steps: steps)
            settleMotion(upTo: filtering.count - motionHalf, into: &out)
        } else {
            stream(target, dt: steps * interval, into: &out)
        }
        return emit(out)
    }

    /// Au lever : tout ce que les étages retiennent encore, jusqu'à la dernière position de la main.
    public mutating func finish() -> [Output] {
        var out: [SIMD3<Double>] = []
        if motionHalf > 0 {
            filtering.close()
            settleMotion(upTo: filtering.count, into: &out)
        }
        streamOn(into: &out)
        if stableHalf > 0 {
            stable.close()
            settleStable(upTo: stable.count, into: &out)
        }
        return emit(out)
    }

    private mutating func emit(_ points: [SIMD3<Double>]) -> [Output] {
        var result: [Output] = []
        for p in points {
            if skipFirst {
                skipFirst = false
                continue
            }
            // Main immobile (un toucher) : aucune moyenne ne doit faire croire à un mouvement.
            let position = moved ? SIMD2(p.x, p.y) : SIMD2(first!.x, first!.y)
            result.append((position, min(1, max(0, p.z))))
        }
        return result
    }

    private mutating func settleMotion(upTo end: Int, into out: inout [SIMD3<Double>]) {
        var i = filtering.settled
        let half = motionHalf
        while i < end {
            var sum = SIMD3<Double>.zero
            for (k, w) in motion.enumerated() { sum += w * filtering.lane(i - half + k) }
            stream(sum, dt: interval, into: &out)
            i += 1
        }
        filtering.settled = max(filtering.settled, i)
    }

    private mutating func stream(_ target: SIMD3<Double>, dt: Double, into out: inout [SIMD3<Double>]) {
        guard streams else {
            smoothed = target
            stabilize(target, samples: dt / interval, into: &out)
            return
        }
        window.append((target, dt))
        let reach = Self.streamWindow - interval
        var age = window.dropFirst().reduce(0.0) { $0 + $1.dt }
        while age >= reach, !window.isEmpty {
            let next = window.removeFirst()
            age -= window.first?.dt ?? 0
            streamTo(next.point, dt: next.dt, near: .zero, into: &out)
        }
    }

    /// Part du chemin vers chaque nouveau point (position, pression) par échantillon de référence (1 : pas de lissage).
    private var strengths: SIMD2<Double> {
        [1 - Self.streamlineKeep(settings.streamLine), 1 - Self.pressureKeep(settings.pressureSmoothing)]
    }

    /// `near` : proximité de l'entrée dans la fenêtre (0 hors fenêtre, 1 pour le point le plus récent, rejoint).
    private mutating func streamTo(_ to: SIMD3<Double>, dt: Double, near: SIMD2<Double>, into out: inout [SIMD3<Double>]) {
        let steps = dt / interval
        func follow(_ strength: Double, _ near: Double) -> Double {
            let follows = strength + near * (near - strength)
            return 1 - pow(max(0, 1 - follows), steps)
        }
        let s = strengths
        let next: SIMD3<Double>
        if let previous = smoothed {
            let position = s.x < 1 ? follow(s.x, near.x) : 1
            let pressure = s.y < 1 ? follow(s.y, near.y) : 1
            next = SIMD3(previous.x + (to.x - previous.x) * position, previous.y + (to.y - previous.y) * position,
                         previous.z + (to.z - previous.z) * pressure)
        } else {
            next = to
        }
        smoothed = next
        stabilize(next, samples: min(Self.mostSteps, steps), into: &out)
    }

    /// Vide la fenêtre du StreamLine comme si plus rien ne venait : le trait se recourbe jusqu'à la main.
    private mutating func streamOn(into out: inout [SIMD3<Double>]) {
        let s = strengths
        let reach = Self.streamWindow - interval
        var age = window.dropFirst().reduce(0.0) { $0 + $1.dt }
        while !window.isEmpty {
            let next = window.removeFirst()
            let base = max(0, 1 - age / reach)
            streamTo(next.point, dt: next.dt, near: [pow(base, 1 - s.x), pow(base, 1 - s.y)], into: &out)
            age -= window.first?.dt ?? 0
        }
    }

    private mutating func stabilize(_ point: SIMD3<Double>, samples: Double, into out: inout [SIMD3<Double>]) {
        guard stableHalf > 0 else {
            out.append(point)
            return
        }
        stable.add(point, steps: max(samples, 1e-6))
        settleStable(upTo: stable.count - stableHalf, into: &out)
    }

    private mutating func settleStable(upTo end: Int, into out: inout [SIMD3<Double>]) {
        var i = stable.settled
        let half = stableHalf
        while i < end {
            var sum = SIMD3<Double>.zero
            for j in (i - half)...(i + half) { sum += stable.lane(j) }
            out.append(sum / Double(2 * half + 1))
            i += 1
        }
        stable.settled = max(stable.settled, i)
    }
}

/// Vitesse du trait pour la dynamique de vitesse, dans [0, 1], mesurée à l'écran comme dans ProCraft : nulle jusqu'à
/// 25 points d'écran par image de 60 Hz, puis croissante (racine carrée) jusqu'à 125 ; lissée sur trois images.
public struct StrokeSpeed: Sendable {
    static let slow = 25.0
    static let span = 100.0
    static let frames = 3.0

    public private(set) var value = 0.0
    private var known = false

    public init() {}

    /// La main a parcouru `points` points d'écran en `seconds` secondes.
    public mutating func add(points: Double, seconds: Double) {
        guard seconds > 0 else { return }
        let elapsedFrames = seconds * 60
        let perFrame = points / elapsedFrames
        let over = (perFrame - Self.slow) / Self.span
        let now = over > 0 ? min(1, over.squareRoot()) : 0
        let held = known ? Self.frames / elapsedFrames : 0
        value = min(1, max(0, (now + held * value) / (held + 1)))
        known = true
    }

    /// Ce qu'une dynamique de vitesse `amount` laisse d'une taille ou d'une opacité : plus vite retire autant que
    /// `amount` ; un `amount` négatif retire au contraire quand on va lentement.
    public static func scale(amount: Double, speed: Double) -> Double {
        let s = min(1, max(0, speed))
        return amount >= 0 ? 1 - amount * s : 1 + amount * (1 - s)
    }
}
