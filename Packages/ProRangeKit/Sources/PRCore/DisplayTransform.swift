import Foundation
import simd

extension ToneMapping {
    /// Implémentation de référence CPU des courbes du shader d'affichage (`toneMap` dans PanoramaShaders) :
    /// linéaire en entrée, linéaire dans [0, 1] en sortie (l'encodage sRGB vient après).
    public func apply(_ c: SIMD3<Float>) -> SIMD3<Float> {
        switch self {
        case .clip: return simd_clamp(c, .zero, .one)
        case .agx: return Self.agx(c)
        case .aces:
            let a: SIMD3<Float> = 2.51 * c + 0.03
            let b: SIMD3<Float> = 2.43 * c + 0.59
            let numerator: SIMD3<Float> = c * a
            let denominator: SIMD3<Float> = c * b + 0.14
            return simd_clamp(numerator / denominator, .zero, .one)
        case .filmic:
            let white: SIMD3<Float> = Self.hable(SIMD3<Float>(repeating: 11.2))
            return simd_clamp(Self.hable(c * 2) / white, .zero, .one)
        }
    }

    private static let agxInset = simd_float3x3(columns: (
        SIMD3<Float>(0.842479062253094, 0.0423282422610123, 0.0423756549057051),
        SIMD3<Float>(0.0784335999999992, 0.878468636469772, 0.0784336),
        SIMD3<Float>(0.0792237451477643, 0.0791661274605434, 0.879142973793104)))
    private static let agxOutset = simd_float3x3(columns: (
        SIMD3<Float>(1.19687900512017, -0.0528968517574562, -0.0529716355144438),
        SIMD3<Float>(-0.0980208811401368, 1.15190312990417, -0.0980434501171241),
        SIMD3<Float>(-0.0990297440797205, -0.0989611768448433, 1.15107367264116)))

    private static func agx(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let minEV: Float = -12.47393
        let maxEV: Float = 4.026069
        let inset = agxInset * simd_max(c, SIMD3<Float>(repeating: 1e-10))
        var v = SIMD3<Float>(log2f(inset.x), log2f(inset.y), log2f(inset.z))
        let clamped: SIMD3<Float> = simd_clamp(v, SIMD3<Float>(repeating: minEV), SIMD3<Float>(repeating: maxEV))
        v = (clamped - minEV) / (maxEV - minEV)
        let x2: SIMD3<Float> = v * v
        let x4: SIMD3<Float> = x2 * x2
        let t6: SIMD3<Float> = 15.5 * (x4 * x2)
        let t5: SIMD3<Float> = 40.14 * (x4 * v)
        let t4: SIMD3<Float> = 31.96 * x4
        let t3: SIMD3<Float> = 6.868 * (x2 * v)
        let t2: SIMD3<Float> = 0.4298 * x2
        let t1: SIMD3<Float> = 0.1191 * v
        let a: SIMD3<Float> = t6 - t5 + t4
        let b: SIMD3<Float> = t2 - t3 + t1 - 0.00232
        let out = simd_max(agxOutset * (a + b), .zero)
        return simd_clamp(SIMD3<Float>(powf(out.x, 2.2), powf(out.y, 2.2), powf(out.z, 2.2)), .zero, .one)
    }

    private static func hable(_ x: SIMD3<Float>) -> SIMD3<Float> {
        let a: Float = 0.15, b: Float = 0.50, c: Float = 0.10, d: Float = 0.20, e: Float = 0.02, f: Float = 0.30
        let cb: Float = c * b
        let de: Float = d * e
        let df: Float = d * f
        let inner1: SIMD3<Float> = a * x + cb
        let inner2: SIMD3<Float> = a * x + b
        let numerator: SIMD3<Float> = x * inner1 + de
        let denominator: SIMD3<Float> = x * inner2 + df
        return numerator / denominator - e / f
    }
}

/// Passage d'une valeur HDR (linéaire prémultipliée) à une valeur d'écran : exposition, courbe, encodage sRGB.
/// Sert aux exports 8 et 16 bits entiers (PNG, JPG), qui doivent ressembler à ce qu'on voit dans l'app.
public struct DisplayTransform: Equatable, Sendable {
    /// Exposition en EV (×2^ev avant la courbe).
    public var exposure: Double
    public var toneMapping: ToneMapping

    public init(exposure: Double = 0, toneMapping: ToneMapping = .clip) {
        self.exposure = exposure
        self.toneMapping = toneMapping
    }

    /// Couleur encodée sRGB dans [0, 1], **non prémultipliée**, et alpha.
    public func encode(_ p: SIMD4<Float>) -> SIMD4<Float> {
        let alpha = min(1, max(0, p.w))
        guard alpha > 0 else { return .zero }
        let straight = SIMD3<Float>(p.x, p.y, p.z) / p.w
        let mapped = toneMapping.apply(straight * Float(exp2(exposure)))
        let encoded = ColorTransfer.toEncoded(mapped)
        return SIMD4<Float>(encoded.x, encoded.y, encoded.z, alpha)
    }
}
