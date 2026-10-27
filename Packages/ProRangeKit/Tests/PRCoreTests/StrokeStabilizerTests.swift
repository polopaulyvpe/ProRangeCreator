import PRCore
import simd
import XCTest

final class StrokeStabilizerTests: XCTestCase {
    /// Trait horizontal tremblé (± 0,02 en y, alterné).
    private func shakyLine() -> [SIMD2<Double>] {
        (0..<60).map { i in SIMD2(Double(i) * 0.01, i % 2 == 0 ? 0.02 : -0.02) }
    }

    private func wobble(_ points: [SIMD2<Double>]) -> Double {
        points.dropFirst(10).map { abs($0.y) }.max() ?? 0
    }

    func testNoSettingsPassesThrough() {
        var s = StrokeStabilizer(settings: .init())
        XCTAssertFalse(s.settings.isActive)
        for p in shakyLine() {
            let out = s.add(p, pressure: 0.3)
            XCTAssertEqual(out.point, p)
            XCTAssertEqual(out.pressure, 0.3)
        }
    }

    func testEachSettingReducesTheWobble() {
        let raw = wobble(shakyLine())
        for settings in [StrokeStabilizer.Settings(streamLine: 0.8), StrokeStabilizer.Settings(stabilization: 0.5),
                         StrokeStabilizer.Settings(motionFiltering: 1)] {
            var s = StrokeStabilizer(settings: settings)
            let out = shakyLine().map { s.add($0, pressure: 1).point }
            XCTAssertLessThan(wobble(out), raw * 0.5, "\(settings)")
            XCTAssertGreaterThan(out.last!.x, 0.3, "le trait avance toujours")
        }
    }

    func testStreamLineCatchesUpOnLift() {
        var s = StrokeStabilizer(settings: .init(streamLine: 0.9))
        var last = SIMD2<Double>.zero
        for i in 0..<20 { last = s.add([Double(i) * 0.05, 0], pressure: 0.5).point }
        XCTAssertLessThan(last.x, 0.95 - 0.05, "en retard sur la main")
        let tail = s.finish(step: 0.01)
        XCTAssertFalse(tail.isEmpty)
        XCTAssertEqual(tail.last!.point.x, 0.95, accuracy: 1e-9, "rattrape la dernière position")
    }

    func testPressureSmoothing() {
        var s = StrokeStabilizer(settings: .init(pressureSmoothing: 1))
        _ = s.add(.zero, pressure: 0)
        let jump = s.add([0.01, 0], pressure: 1).pressure
        XCTAssertEqual(jump, 0.1, accuracy: 1e-9, "la pression monte doucement")
    }
}
