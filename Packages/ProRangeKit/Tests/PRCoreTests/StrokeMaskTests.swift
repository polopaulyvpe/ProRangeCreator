import PRCore
import XCTest

final class StrokeMaskTests: XCTestCase {
    func testPressureCurveIsMonotoneAndPassesThroughItsPoints() {
        XCTAssertTrue(PressureCurve.linear.isLinear)
        XCTAssertEqual(PressureCurve.linear.value(0.3), 0.3, accuracy: 1e-12)
        let curve = PressureCurve(points: [[0, 0], [1, 1], [0.375, 0.497], [0.7, 0.72]])
        XCTAssertEqual(curve.points.map(\.x), [0, 0.375, 0.7, 1], "points triés")
        XCTAssertEqual(curve.value(0.375), 0.497, accuracy: 1e-9)
        XCTAssertEqual(curve.value(0.7), 0.72, accuracy: 1e-9)
        var previous = -1.0
        for i in 0...200 {
            let y = curve.value(Double(i) / 200)
            XCTAssertGreaterThanOrEqual(y, previous - 1e-12, "monotone")
            XCTAssertTrue((0...1).contains(y))
            previous = y
        }
        // Un plateau reste plat (pas de dépassement).
        let flat = PressureCurve(points: [[0, 0], [0.3, 0.5], [0.7, 0.5], [1, 1]])
        XCTAssertEqual(flat.value(0.5), 0.5, accuracy: 1e-9)
    }

    func testGlazeCapsAtDabOpacityAndIntenseBuildsUp() {
        let glaze = StrokeStyle(color: [1, 1, 1], capsPrimary: true)
        let intense = StrokeStyle(color: [1, 1, 1], capsPrimary: false)
        var m = SIMD4<Float>.zero
        for _ in 0..<10 { StrokeMask.accumulate(&m, coverage: 1, opacity: 0.4, flow: 1, secondary: false) }
        XCTAssertEqual(StrokeMask.alpha(m, style: glaze), 0.4, accuracy: 1e-6, "le glacis ne fonce pas en repassant")
        XCTAssertGreaterThan(StrokeMask.alpha(m, style: intense), 0.99, "l'accumulation monte vers l'opaque")

        // Flux faible : le glacis monte progressivement vers le plafond.
        var low = SIMD4<Float>.zero
        StrokeMask.accumulate(&low, coverage: 1, opacity: 0.8, flow: 0.2, secondary: false)
        let first = StrokeMask.alpha(low, style: glaze)
        XCTAssertEqual(first, 0.16, accuracy: 1e-6)
        for _ in 0..<40 { StrokeMask.accumulate(&low, coverage: 1, opacity: 0.8, flow: 0.2, secondary: false) }
        XCTAssertEqual(StrokeMask.alpha(low, style: glaze), 0.8, accuracy: 1e-6)
    }

    func testHardMixDualBrushIsCrispAndBreaksWhereSecondaryIsThin() {
        let style = StrokeStyle(color: [1, 1, 1], dual: .hardMix)
        func alpha(primary: Float, secondary: Float) -> Float {
            var m = SIMD4<Float>.zero
            StrokeMask.accumulate(&m, coverage: 1, opacity: primary, flow: 1, secondary: false)
            StrokeMask.accumulate(&m, coverage: 1, opacity: secondary, flow: 1, secondary: true)
            return StrokeMask.alpha(m, style: style)
        }
        XCTAssertEqual(alpha(primary: 0.3, secondary: 1), 1, "plein là où le secondaire couvre")
        XCTAssertEqual(alpha(primary: 0.3, secondary: 0.5), 0, "cassé là où il est mince")
        XCTAssertEqual(alpha(primary: 0, secondary: 1), 0, "jamais hors du principal")
        XCTAssertEqual(DualBlendMode(procreateCode: 20), .hardMix)
        XCTAssertEqual(DualBlendMode(procreateCode: 0), .multiply)
        XCTAssertEqual(DualBlendMode.multiply.combine(0.5, 0.5), 0.25)
    }

    func testCompositeKeepsTheOriginalWhereTheStrokeIsAbsent() {
        let original = SIMD4<Float>(0.2, 0.1, 0.05, 0.5)
        let style = StrokeStyle(color: [1, 0, 0])
        XCTAssertEqual(StrokeMask.composite(original, alpha: 0, style: style, space: .linear, alphaLock: false), original)
        let full = StrokeMask.composite(original, alpha: 1, style: style, space: .linear, alphaLock: false)
        XCTAssertEqual(full, [1, 0, 0, 1])
        let erased = StrokeMask.composite(original, alpha: 1, style: StrokeStyle(color: .zero, mode: .erase), space: .perceptual,
                                          alphaLock: false)
        XCTAssertEqual(erased, .zero)
    }

    func testGrainBlendRollingGrainAndJitters() {
        // Fusion du grain : produit = l'ancien calcul ; densité linéaire + = le grain creuse la forme.
        var tip = DabTip(grain: BrushTexture(name: "g", size: 1, values: [0.4]), grainDepth: 1)
        XCTAssertEqual(tip.applyGrain(0.5, 0.4), 0.2, accuracy: 1e-6)
        tip.grainBlend = .linearBurn
        XCTAssertEqual(tip.applyGrain(0.5, 0.4), 0, "0,5 + 0,4 − 1 < 0 : trou")
        XCTAssertEqual(tip.applyGrain(1, 0.4), 0.4, accuracy: 1e-6)

        // Rouleau : le décalage du grain avance avec la longueur du trait, dans sa direction.
        var brush = BrushSettings.defaultBrush
        brush.grainSource = BrushTexture(name: "g", size: 2, values: [0, 1, 1, 0])
        brush.refreshGrain()
        brush.grainMoving = true
        brush.grainScaleDegrees = 2
        brush.grainMovement = 1
        let scale = 2 * Double.pi / 180
        let a = brush.dab(at: [0, 0, -1], pressure: 1, color: .one, mode: .paint, context: StrokeContext(distance: 0))
        let b = brush.dab(at: [0, 0, -1], pressure: 1, color: .one, mode: .paint, context: StrokeContext(distance: 0.1))
        XCTAssertEqual(b.tip!.grainOffset.x - a.tip!.grainOffset.x, 0.1 / scale, accuracy: 1e-9)
        XCTAssertEqual(b.tip!.grainOffset.y, 0, accuracy: 1e-9)
        brush.grainMovement = 0
        let glide = brush.dab(at: [0, 0, -1], pressure: 1, color: .one, mode: .paint, context: StrokeContext(distance: 0.1))
        XCTAssertEqual(glide.tip!.grainOffset, .zero, "glisse : le grain reste collé au tampon")

        // Variation linéaire : décalage le long du trait (ici vers l'est), pas en travers.
        var jitter = BrushSettings.defaultBrush
        jitter.longitudinalJitter = 1
        var random = DabRandom.none
        random.along = 1
        let moved = jitter.dab(at: [0, 0, -1], pressure: 1, color: .one, mode: .paint, random: random)
        let p = TangentFrame(center: [0, 0, -1]).project(moved.center)
        XCTAssertGreaterThan(p.x, 0)
        XCTAssertEqual(p.y, 0, accuracy: 1e-9)

        // Vitesse → espacement.
        jitter.speedSpacing = 1
        XCTAssertEqual(jitter.spacing(radius: 1, random: 0.5, speed: 3), 2 * jitter.spacing(radius: 1, random: 0.5), accuracy: 1e-12)
    }

    func testFlowAndCurvesInBrushSettings() {
        var brush = BrushSettings.defaultBrush
        brush.flow = 0.5
        brush.pressureFlowAmount = 1
        XCTAssertEqual(brush.flow(pressure: 1), 0.5, accuracy: 1e-12)
        XCTAssertEqual(brush.flow(pressure: 0.5), 0.25, accuracy: 1e-12)
        brush.rendering = .uniformGlaze
        XCTAssertEqual(brush.flow(pressure: 0.5), 0.5, accuracy: 1e-12, "uniforme : la pression ne change pas le flux")
        let dab = brush.dab(at: [0, 0, -1], pressure: 0.5, color: [1, 1, 1], mode: .paint)
        XCTAssertEqual(dab.flow, 0.5, accuracy: 1e-6)

        brush.pressureCurve = PressureCurve(points: [[0, 0], [0.5, 1], [1, 1]])
        brush.minimumSize = 0
        XCTAssertEqual(brush.radius(pressure: 0.5), brush.radius(pressure: 1), accuracy: 1e-12, "courbe saturée à mi-pression")

        var double = BrushSettings.defaultBrush
        XCTAssertNil(double.strokeStyle(color: .one, mode: .paint).dual)
        double.secondary = BrushSettings(radiusDegrees: 9)
        double.secondaryScale = 2
        double.radiusDegrees = 3
        XCTAssertEqual(double.resolvedSecondary?.radiusDegrees, 6, "le secondaire suit la taille du principal")
        XCTAssertEqual(double.strokeStyle(color: .one, mode: .paint).dual, .multiply)
    }
}
