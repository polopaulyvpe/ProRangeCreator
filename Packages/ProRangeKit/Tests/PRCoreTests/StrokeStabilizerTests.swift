import PRCore
import simd
import XCTest

final class StrokeStabilizerTests: XCTestCase {
    /// Trait horizontal tremblé (± 0,02 en y, alterné), une mesure tous les 1/240 s.
    private func shakyLine(count: Int = 120) -> [SIMD2<Double>] {
        (0..<count).map { i in SIMD2(Double(i) * 0.01, i % 2 == 0 ? 0.02 : -0.02) }
    }

    /// Tout le trait lissé : premier point, mesures, puis le lever.
    private func run(_ settings: StrokeStabilizer.Settings, _ points: [SIMD2<Double>], pressures: [Double]? = nil,
                     rate: Double = 240) -> [StrokeStabilizer.Output] {
        var s = StrokeStabilizer(settings: settings, pen: true)
        let pressure = { (i: Int) in pressures?[i] ?? 1 }
        var out = [s.begin(points[0], pressure: pressure(0), time: 0)]
        for i in 1..<points.count { out += s.add(points[i], pressure: pressure(i), time: Double(i) / rate) }
        out += s.finish()
        return out
    }

    private func wobble(_ points: [StrokeStabilizer.Output]) -> Double {
        points.dropFirst(points.count / 4).dropLast(points.count / 4).map { abs($0.point.y) }.max() ?? 0
    }

    func testNoSettingsPassesThrough() {
        let line = shakyLine(count: 20)
        let out = run(.init(), line, pressures: (0..<20).map { Double($0) / 20 })
        XCTAssertEqual(out.count, line.count)
        for (i, p) in out.enumerated() {
            XCTAssertEqual(p.point, line[i])
            XCTAssertEqual(p.pressure, Double(i) / 20, accuracy: 1e-12)
        }
    }

    func testEachSettingReducesTheWobbleAndEndsOnThePen() {
        let line = shakyLine()
        let raw = 0.02
        for settings in [StrokeStabilizer.Settings(streamLine: 0.8), StrokeStabilizer.Settings(stabilization: 0.5),
                         StrokeStabilizer.Settings(motionFiltering: 0.3)] {
            let out = run(settings, line)
            XCTAssertLessThan(wobble(out), raw * 0.5, "\(settings)")
            XCTAssertEqual(out.first!.point, line[0], "commence sur la mine")
            XCTAssertEqual(out.last!.point.x, line.last!.x, accuracy: 0.03, "finit sur la mine : \(settings)")
        }
    }

    func testStreamLineLagsThenCatchesUpOnLift() {
        var s = StrokeStabilizer(settings: .init(streamLine: 0.9), pen: true)
        _ = s.begin(.zero, pressure: 1, time: 0)
        var latest = SIMD2<Double>.zero
        for i in 1...60 {
            if let p = s.add([Double(i) * 0.01, 0], pressure: 1, time: Double(i) / 240).last { latest = p.point }
        }
        XCTAssertLessThan(latest.x, 0.6 - 0.05, "en retard sur la main")
        let tail = s.finish()
        XCTAssertFalse(tail.isEmpty)
        XCTAssertEqual(tail.last!.point.x, 0.6, accuracy: 1e-9, "rejoint la dernière position")
    }

    /// Le même geste mesuré à 240 et à 120 Hz est lissé de la même façon.
    func testStreamLineDoesNotDependOnTheInputRate() {
        func lagAtTheEnd(rate: Double) -> Double {
            var s = StrokeStabilizer(settings: .init(streamLine: 0.7), pen: true)
            _ = s.begin(.zero, pressure: 1, time: 0)
            var latest = SIMD2<Double>.zero
            let count = Int(rate / 4) // un quart de seconde à 2,4 unités par seconde
            for i in 1...count {
                let t = Double(i) / rate
                if let p = s.add([t * 2.4, 0], pressure: 1, time: t).last { latest = p.point }
            }
            return 0.6 - latest.x
        }
        let fast = lagAtTheEnd(rate: 240), slow = lagAtTheEnd(rate: 120)
        XCTAssertGreaterThan(fast, 0.01)
        // (Écart résiduel : la fenêtre de 50 ms se vide par mesures entières, 4 ou 8 ms.)
        XCTAssertEqual(fast, slow, accuracy: 0.03)
    }

    func testTapStaysInPlace() {
        let out = run(.init(streamLine: 0.5, stabilization: 0.5, motionFiltering: 0.2), Array(repeating: [0.3, -0.2], count: 10))
        for p in out { XCTAssertEqual(p.point, [0.3, -0.2]) }
    }

    func testPressureSmoothingRisesGradually() {
        let line = (0..<40).map { SIMD2(Double($0) * 0.01, 0) }
        let out = run(.init(pressureSmoothing: 0.6), line, pressures: [0] + Array(repeating: 1, count: 39))
        XCTAssertLessThan(out[2].pressure, 0.5, "la pression monte doucement")
        XCTAssertEqual(out.last!.pressure, 1, accuracy: 1e-9, "et rejoint celle de la mine au lever")
    }

    func testMotionWeightsAreASymmetricLowPass() {
        XCTAssertTrue(StrokeStabilizer.motionWeights(amount: 0, rate: 240).isEmpty)
        let weights = StrokeStabilizer.motionWeights(amount: 0.3, rate: 240)
        XCTAssertEqual(weights.count % 2, 1)
        XCTAssertEqual(weights.reduce(0, +), 1, accuracy: 1e-9)
        for k in 0..<(weights.count / 2) {
            XCTAssertEqual(weights[k], weights[weights.count - 1 - k], accuracy: 1e-12)
        }
        XCTAssertEqual(weights.firstIndex(of: weights.max()!), weights.count / 2, "le centre pèse le plus")
        // Un tremblement à la fréquence d'échantillonnage moitié disparaît presque entièrement.
        let alternating = weights.enumerated().reduce(0.0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : -1) }
        XCTAssertLessThan(abs(alternating), 0.01)
        let stronger = StrokeStabilizer.motionWeights(amount: 0.6, rate: 240)
        XCTAssertGreaterThan(stronger.count, weights.count, "plus fort = plus long")
    }

    func testSpeedIsMeasuredOnScreen() {
        var slow = StrokeSpeed()
        for _ in 0..<10 { slow.add(points: 20, seconds: 1.0 / 60) }
        XCTAssertEqual(slow.value, 0, "en dessous de 25 points par image : nulle")
        var fast = StrokeSpeed()
        for _ in 0..<30 { fast.add(points: 125, seconds: 1.0 / 60) }
        XCTAssertEqual(fast.value, 1, accuracy: 1e-6)
        var middle = StrokeSpeed()
        middle.add(points: 50, seconds: 1.0 / 60)
        XCTAssertEqual(middle.value, 0.5, accuracy: 1e-9, "racine carrée de (50 − 25) / 100")
        XCTAssertEqual(StrokeSpeed.scale(amount: 0.5, speed: 1), 0.5)
        XCTAssertEqual(StrokeSpeed.scale(amount: -0.5, speed: 0), 0.5, "réglage négatif : agit à vitesse lente")
        XCTAssertEqual(StrokeSpeed.scale(amount: -0.5, speed: 1), 1)
    }
}
