import PRCore
import simd
import XCTest

final class ViewStateTests: XCTestCase {
    private let center = SIMD2<Double>(0, 0)

    func testSphereLooksAlongYawAndPitch() throws {
        var view = ViewState()
        assertClose(try XCTUnwrap(view.direction(atNDC: center, aspect: 1.5)), [0, 0, -1])
        view.yaw = .pi / 2
        assertClose(try XCTUnwrap(view.direction(atNDC: center, aspect: 1.5)), [1, 0, 0])
        view.yaw = 0
        view.pitch = .pi / 4
        assertClose(try XCTUnwrap(view.direction(atNDC: center, aspect: 1.5)), [0, sin(.pi / 4), -cos(.pi / 4)])
    }

    func testRectilinearEdgesMatchFieldOfView() throws {
        let view = ViewState() // champ vertical 90°
        let top = try XCTUnwrap(view.direction(atNDC: [0, 1], aspect: 1))
        XCTAssertEqual(Sphere.angle(top, [0, 0, -1]), .pi / 4, accuracy: 1e-12)
        let right = try XCTUnwrap(view.direction(atNDC: [1, 0], aspect: 2))
        XCTAssertEqual(Sphere.angle(right, [0, 0, -1]), atan(2), accuracy: 1e-12)
        XCTAssertGreaterThan(right.x, 0, "la droite de l'écran est vers +X")
    }

    func testUnfoldedViewMapsScreenToEquirect() throws {
        var view = ViewState()
        view.mode = .unfolded
        view.morph = 1
        for p in [SIMD2<Double>(-0.9, 0.8), [0.3, -0.5], [0.99, 0.99], [0, 0]] {
            let d = try XCTUnwrap(view.direction(atNDC: p, aspect: 2))
            let expected = Equirect.direction(u: 0.5 + p.x / 2, v: 0.5 - p.y / 2)
            assertClose(d, expected)
        }
        view.unfoldedSpan = 0.5
        XCTAssertNotNil(view.direction(atNDC: [0, 1], aspect: 2), "dans le panorama")
        view.unfoldedCenter = [0.5, 0.1]
        XCTAssertNil(view.direction(atNDC: [0, 1], aspect: 2), "au-dessus du zénith : hors panorama")
    }

    func testMorphEndpoints() throws {
        var view = ViewState()
        view.yaw = 0.7
        view.pitch = -0.2
        let p = SIMD2<Double>(0.4, -0.3)
        let rect = view.parameters(aspect: 1.5).rectilinearDirection(ndc: p)
        view.morph = 0
        assertClose(try XCTUnwrap(view.direction(atNDC: p, aspect: 1.5)), rect)
        view.mode = .unfolded
        view.morph = 1
        let uv = view.parameters(aspect: 1.5).unfoldedUV(ndc: p)
        assertClose(try XCTUnwrap(view.direction(atNDC: p, aspect: 1.5)), Equirect.direction(u: uv.x, v: uv.y))
        view.morph = 0.5
        let mid = try XCTUnwrap(view.direction(atNDC: p, aspect: 1.5))
        XCTAssertEqual(simd_length(mid), 1, accuracy: 1e-12)
    }

    func testUnfoldCentersOnLookDirectionAndFoldsBack() throws {
        var view = ViewState()
        view.yaw = 1.1
        view.pitch = 0.3
        let look = try XCTUnwrap(view.direction(atNDC: center, aspect: 1))
        view.prepareUnfold()
        view.mode = .unfolded
        view.morph = 1
        assertClose(try XCTUnwrap(view.direction(atNDC: center, aspect: 1)), look)

        view.unfoldedCenter = [0.3, 0.4]
        let unfoldedLook = try XCTUnwrap(view.direction(atNDC: center, aspect: 1))
        view.prepareFold()
        view.mode = .sphere
        view.morph = 0
        assertClose(try XCTUnwrap(view.direction(atNDC: center, aspect: 1)), unfoldedLook)
    }

    func testFlatFacesLookAtCubeFaces() throws {
        var view = ViewState()
        let expected: [CubeFace: Vec3] = [.front: [0, 0, -1], .right: [1, 0, 0], .back: [0, 0, 1],
                                          .left: [-1, 0, 0], .up: [0, 1, 0], .down: [0, -1, 0]]
        for (face, dir) in expected {
            view.showFace(face)
            view.morph = 1 // ignoré en fenêtre plane
            assertClose(try XCTUnwrap(view.direction(atNDC: center, aspect: 1)), dir)
        }
    }

    func testGestures() {
        var view = ViewState()
        view.zoom(by: 10)
        XCTAssertEqual(view.fov, ViewState.fovRange.lowerBound, accuracy: 1e-12)
        view.zoom(by: 0.01)
        XCTAssertEqual(view.fov, ViewState.fovRange.upperBound, accuracy: 1e-12)

        view = ViewState()
        view.pan(byNDC: [0.2, 0], aspect: 1)
        XCTAssertLessThan(view.yaw, 0, "glisser vers la droite fait tourner la vue vers la gauche")
        view.pan(byNDC: [0, 5], aspect: 1)
        view.pan(byNDC: [0, 5], aspect: 1)
        XCTAssertGreaterThan(view.pitch, -.pi / 2, "le tangage reste borné")

        view.rotate(by: 0.3)
        XCTAssertEqual(view.roll, 0, "horizon verrouillé par défaut")
        view.horizonLocked = false
        view.rotate(by: 0.3)
        XCTAssertEqual(view.roll, 0.3)

        view.mode = .unfolded
        view.unfoldedCenter = [0.02, 0.5]
        view.pan(byNDC: [0.5, 0], aspect: 2)
        XCTAssertTrue((0..<1).contains(view.unfoldedCenter.x), "le centre boucle sur la couture")
    }

    private func assertClose(_ a: Vec3, _ b: Vec3, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_length(a - b), 1e-9, "\(a) ≠ \(b)", file: file, line: line)
    }
}
