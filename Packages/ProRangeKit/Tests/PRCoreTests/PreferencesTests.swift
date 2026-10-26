import Foundation
import PRCore
import XCTest

final class PreferencesTests: XCTestCase {
    func testRoundTripAndTolerantDecoding() throws {
        var prefs = Preferences()
        prefs.theme = .light
        prefs.leftHanded = true
        prefs.fourFingerTap = .toggleUnfold
        prefs.toneMapping = .agx
        prefs.blendSpace = .linear
        prefs.historyLimit = 250
        XCTAssertEqual(Preferences.decode(prefs.encoded()), prefs)

        // Champ inconnu, champ manquant, valeur illisible : les autres réglages sont gardés.
        let partial = #"{"leftHanded": true, "theme": "violet", "futur": 3}"#
        let decoded = Preferences.decode(Data(partial.utf8))
        XCTAssertTrue(decoded.leftHanded)
        XCTAssertEqual(decoded.theme, .dark, "valeur illisible : défaut")
        XCTAssertEqual(decoded.historyLimit, 1000)
        XCTAssertEqual(Preferences.decode(nil), Preferences())
        XCTAssertEqual(Preferences.decode(Data("pas du json".utf8)), Preferences())
    }

    func testPressureCurve() {
        var prefs = Preferences()
        XCTAssertEqual(prefs.mappedPressure(0.5), 0.5, accuracy: 1e-12, "linéaire par défaut")
        prefs.pressureGamma = 2
        XCTAssertEqual(prefs.mappedPressure(0.5), 0.25, accuracy: 1e-12, "ferme : il faut appuyer plus")
        prefs.pressureGamma = 0.5
        XCTAssertEqual(prefs.mappedPressure(0.25), 0.5, accuracy: 1e-12, "douce")
        XCTAssertEqual(prefs.mappedPressure(1.7), 1, "borné")
        XCTAssertEqual(prefs.mappedPressure(-1), 0)
    }
}
