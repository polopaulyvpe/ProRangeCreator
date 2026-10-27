import simd

/// Stabilisation du tracé, comme dans l'Atelier de Procreate, appliquée aux points de l'écran avant la projection :
/// - Stabilisation : moyenne glissante des derniers points (gomme les tremblements, surtout en allant lentement) ;
/// - Filtrage du mouvement : zone morte qui ignore les petits écarts autour du dernier point retenu ;
/// - StreamLine : le trait suit la main avec un retard élastique (courbes lisses), puis la rattrape au lever ;
/// - Lissage de la pression : la pression varie moins brusquement.
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

    public let settings: Settings
    /// Longueur de référence de l'écran dans les unités des points (demi-écran en NDC = 1, ou quelques centaines de pixels).
    public let unit: Double
    private var history: [SIMD2<Double>] = []
    private var filtered: SIMD2<Double>?
    private var output: SIMD2<Double>?
    private var pressure: Double?
    private var lastRaw: (point: SIMD2<Double>, pressure: Double)?

    public init(settings: Settings, unit: Double = 1) {
        self.settings = settings
        self.unit = unit
    }

    /// Point stabilisé pour un point brut du trait.
    public mutating func add(_ point: SIMD2<Double>, pressure rawPressure: Double) -> (point: SIMD2<Double>, pressure: Double) {
        lastRaw = (point, rawPressure)
        // Stabilisation : moyenne des N derniers points (N jusqu'à 25).
        let window = 1 + Int((min(1, max(0, settings.stabilization)) * 24).rounded())
        history.append(point)
        if history.count > window { history.removeFirst(history.count - window) }
        let averaged = history.reduce(SIMD2<Double>.zero, +) / Double(history.count)

        // Filtrage du mouvement : le point retenu ne bouge que quand la main s'en éloigne de plus que la zone morte.
        let deadZone = min(1, max(0, settings.motionFiltering)) * 0.03 * unit
        if let current = filtered {
            let gap = simd_distance(averaged, current)
            if gap > deadZone { filtered = current + (averaged - current) * ((gap - deadZone) / gap) }
        } else {
            filtered = averaged
        }

        // StreamLine : suivi élastique (0 = immédiat, 1 = très lent).
        let follow = 1 - 0.92 * min(1, max(0, settings.streamLine))
        if let previous = output {
            output = previous + (filtered! - previous) * follow
        } else {
            output = filtered
        }

        let pressureFollow = 1 - 0.9 * min(1, max(0, settings.pressureSmoothing))
        pressure = pressure.map { $0 + (rawPressure - $0) * pressureFollow } ?? rawPressure
        return (output!, pressure!)
    }

    /// Au lever : points qui rattrapent la dernière position de la main (le retard du StreamLine), à peu près tous les
    /// `step` (unités des points).
    public mutating func finish(step: Double) -> [(point: SIMD2<Double>, pressure: Double)] {
        guard let start = output, let end = lastRaw else { return [] }
        let gap = simd_distance(start, end.point)
        guard gap > step * 0.5 else { return [] }
        let count = min(64, max(1, Int(gap / max(step, 1e-9))))
        let p0 = pressure ?? end.pressure
        return (1...count).map { i in
            let t = Double(i) / Double(count)
            return (start + (end.point - start) * t, p0 + (end.pressure - p0) * t)
        }
    }
}
