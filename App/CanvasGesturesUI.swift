import PRCore
import SwiftUI

// Gestes repris de ProCraft (comportement, pas de code) : glisser la pastille de couleur sur la toile pour remplir,
// frotter à trois doigts pour effacer le calque.

extension CanvasSession {
    /// La pastille de couleur est lâchée en `point` (coordonnées de l'écran, celles de la toile) : la zone est remplie.
    func dropColor(at point: CGPoint) {
        colorDragLocation = nil
        // Lâchée sur la barre du haut : rien.
        guard viewSize.width > 0, viewSize.height > 0, point.y > 64 else { return }
        let ndc = SIMD2<Double>(Double(point.x / viewSize.width) * 2 - 1, 1 - Double(point.y / viewSize.height) * 2)
        guard let d = view.direction(atNDC: ndc, aspect: Double(viewSize.width / viewSize.height)) else { return }
        if refuseIfLocked() { return }
        fill(at: d)
        showToast("Remplissage (seuil \(Int((fillThreshold * 100).rounded())) %)")
    }

    /// Frotté à trois doigts : le calque (ou la sélection) est effacé, une entrée d'historique.
    func scrubToClear() {
        strokeCancelled()
        clearLayer()
        showToast("Calque effacé")
    }
}

/// Pastille qui suit le doigt pendant qu'on glisse la couleur vers la toile.
struct ColorDropSwatch: View {
    @Bindable var session: CanvasSession

    var body: some View {
        if let location = session.colorDragLocation {
            Circle()
                .fill(Color(.sRGB, red: session.color.x, green: session.color.y, blue: session.color.z))
                .frame(width: 44, height: 44)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .shadow(radius: 4)
                .position(location)
                .allowsHitTesting(false)
        }
    }
}

/// Reconnaît un frotté : la main va et vient au moins trois fois de plus de 30 points.
struct ScrubDetector {
    private(set) var turns = 0
    private var lastX: Double = 0
    private var direction: Double = 0
    private(set) var fired = false

    init(startX: Double) { lastX = startX }

    /// Nouvelle position horizontale ; vrai une seule fois, quand le frotté est reconnu.
    mutating func moved(to x: Double) -> Bool {
        let dx = x - lastX
        guard abs(dx) > 30 else { return false }
        let now: Double = dx > 0 ? 1 : -1
        if direction != 0, now != direction { turns += 1 }
        direction = now
        lastX = x
        guard turns >= 3, !fired else { return false }
        fired = true
        return true
    }
}
