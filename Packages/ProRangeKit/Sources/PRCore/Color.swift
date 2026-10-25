import Foundation

/// Courbe de transfert sRGB / Display P3 (même courbe), symétrique pour les négatifs,
/// et **prolongée linéairement au-delà de 1** (D4) : même pente qu'en 1, pour garder les valeurs HDR réversibles.
public enum ColorTransfer {
    /// Pente de la courbe encodée en 1 : d/dx (1,055 · x^(1/2,4) − 0,055) = 1,055 / 2,4.
    static let slopeAtOne: Float = 1.055 / 2.4

    public static func toLinear(_ c: Float) -> Float {
        let a = abs(c)
        let l: Float
        if a <= 0.04045 {
            l = a / 12.92
        } else if a <= 1 {
            l = powf((a + 0.055) / 1.055, 2.4)
        } else {
            l = 1 + (a - 1) / slopeAtOne
        }
        return c < 0 ? -l : l
    }

    public static func toEncoded(_ l: Float) -> Float {
        let a = abs(l)
        let c: Float
        if a <= 0.0031308 {
            c = a * 12.92
        } else if a <= 1 {
            c = 1.055 * powf(a, 1 / 2.4) - 0.055
        } else {
            c = 1 + (a - 1) * slopeAtOne
        }
        return l < 0 ? -c : c
    }

    /// Encode une valeur linéaire en octet sRGB, avec écrêtage simple dans [0, 1].
    @inline(__always)
    public static func encode8(_ l: Float) -> UInt8 {
        UInt8(min(1, max(0, toEncoded(l))) * 255 + 0.5)
    }

    public static func toLinear(_ c: SIMD3<Float>) -> SIMD3<Float> { [toLinear(c.x), toLinear(c.y), toLinear(c.z)] }
    public static func toEncoded(_ l: SIMD3<Float>) -> SIMD3<Float> { [toEncoded(l.x), toEncoded(l.y), toEncoded(l.z)] }
}

/// Espace dans lequel le pinceau et les modes de fusion mélangent les couleurs (D4).
public enum BlendSpace: String, Codable, Sendable, CaseIterable {
    /// Sur les valeurs encodées (perceptuelles), comme Procreate : mêmes résultats visuels. Défaut.
    case perceptual
    /// En lumière linéaire : physiquement correct, bords plus doux et plus lumineux.
    case linear

    public var label: String {
        switch self {
        case .perceptual: "Comme Procreate"
        case .linear: "Lumière linéaire"
        }
    }
}

/// Couleur HSB (teinte, saturation, luminosité dans [0, 1]) sur des composantes encodées sRGB, comme un sélecteur de couleur.
public struct HSBColor: Equatable, Sendable {
    public var hue: Double
    public var saturation: Double
    public var brightness: Double

    public init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }

    public init(rgb c: SIMD3<Double>) {
        let maxC = max(c.x, c.y, c.z)
        let minC = min(c.x, c.y, c.z)
        let delta = maxC - minC
        var h = 0.0
        if delta > 0 {
            if maxC == c.x {
                h = (c.y - c.z) / delta
            } else if maxC == c.y {
                h = 2 + (c.z - c.x) / delta
            } else {
                h = 4 + (c.x - c.y) / delta
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        hue = h
        saturation = maxC > 0 ? delta / maxC : 0
        brightness = maxC
    }

    public var rgb: SIMD3<Double> {
        let h = (hue - floor(hue)) * 6
        let sector = Int(h) % 6
        let f = h - floor(h)
        let v = brightness
        let p = v * (1 - saturation)
        let q = v * (1 - saturation * f)
        let t = v * (1 - saturation * (1 - f))
        switch sector {
        case 0: return [v, t, p]
        case 1: return [q, v, p]
        case 2: return [p, v, t]
        case 3: return [p, q, v]
        case 4: return [t, p, v]
        default: return [v, p, q]
        }
    }
}

/// Saisie et affichage hexadécimal (#RRGGBB) de composantes encodées dans [0, 1].
public enum HexColor {
    public static func parse(_ text: String) -> SIMD3<Double>? {
        var s = text.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return [Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255]
    }

    public static func format(_ c: SIMD3<Double>) -> String {
        func byte(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.x), byte(c.y), byte(c.z))
    }
}
