import Foundation

/// Courbe de transfert sRGB / Display P3 (même courbe). Étendue linéairement au-delà de [0, 1] par symétrie de signe ;
/// l'extension HDR au-delà de 1 sera tranchée en phase 3 (D4).
public enum ColorTransfer {
    public static func toLinear(_ c: Float) -> Float {
        let a = abs(c)
        let l = a <= 0.04045 ? a / 12.92 : powf((a + 0.055) / 1.055, 2.4)
        return c < 0 ? -l : l
    }

    public static func toEncoded(_ l: Float) -> Float {
        let a = abs(l)
        let c = a <= 0.0031308 ? a * 12.92 : 1.055 * powf(a, 1 / 2.4) - 0.055
        return l < 0 ? -c : c
    }

    /// Encode une valeur linéaire en octet sRGB, avec écrêtage simple dans [0, 1].
    @inline(__always)
    public static func encode8(_ l: Float) -> UInt8 {
        UInt8(min(1, max(0, toEncoded(l))) * 255 + 0.5)
    }
}
