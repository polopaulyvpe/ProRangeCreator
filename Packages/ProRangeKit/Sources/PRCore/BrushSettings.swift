/// Réglages d'un outil de peinture (pinceau ou gomme) et dynamique de pression.
public struct BrushSettings: Equatable, Sendable {
    /// Rayon maximal (pression pleine), en degrés sur la sphère.
    public var radiusDegrees: Double
    /// Opacité maximale, dans [0, 1].
    public var opacity: Double
    public var hardness: Double
    /// Espacement entre dabs, en fraction du rayon courant.
    public var spacing: Double
    /// La pression fait varier la taille…
    public var pressureAffectsSize: Bool
    /// … et/ou l'opacité.
    public var pressureAffectsOpacity: Bool
    /// Taille à pression nulle, en fraction du rayon maximal.
    public var minimumSize: Double

    public init(radiusDegrees: Double = 2, opacity: Double = 1, hardness: Double = 0.8, spacing: Double = 0.15,
                pressureAffectsSize: Bool = true, pressureAffectsOpacity: Bool = false, minimumSize: Double = 0.15) {
        self.radiusDegrees = radiusDegrees
        self.opacity = opacity
        self.hardness = hardness
        self.spacing = spacing
        self.pressureAffectsSize = pressureAffectsSize
        self.pressureAffectsOpacity = pressureAffectsOpacity
        self.minimumSize = minimumSize
    }

    public static let defaultBrush = BrushSettings()
    public static let defaultEraser = BrushSettings(radiusDegrees: 4, hardness: 0.6, pressureAffectsSize: true)

    /// Rayon en radians pour une pression dans [0, 1] (1 au doigt, qui n'a pas de pression).
    public func radius(pressure: Double) -> Double {
        let p = min(1, max(0, pressure))
        let scale = pressureAffectsSize ? minimumSize + (1 - minimumSize) * p : 1
        return radiusDegrees * scale * .pi / 180
    }

    public func opacity(pressure: Double) -> Double {
        let p = min(1, max(0, pressure))
        return pressureAffectsOpacity ? opacity * p : opacity
    }

    /// Dab pour un point du trait.
    public func dab(at center: Vec3, pressure: Double, color: SIMD3<Float>, mode: DabMode) -> SphericalDab {
        SphericalDab(center: center, radius: radius(pressure: pressure), hardness: hardness,
                     color: SIMD4<Float>(color.x, color.y, color.z, Float(opacity(pressure: pressure))), mode: mode)
    }
}
