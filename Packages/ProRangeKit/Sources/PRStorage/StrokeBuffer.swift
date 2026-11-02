import PRCore

/// Masque d'un trait sur le chemin CPU (voir `StrokeMask`) : par tuile touchée, le masque en demi-flottants
/// (comme la texture du kernel GPU) et les pixels d'avant le trait, d'où chaque texel est recalculé.
public final class StrokeBuffer {
    var masks: [TileCoord: [SIMD4<Float16>]] = [:]
    /// Couleur du trait par texel (RGB, w inutilisé), pour un pinceau à couleur variable (`StrokeStyle.varyingColor`).
    var colors: [TileCoord: [SIMD4<Float16>]] = [:]
    /// Pixels bruts de la tuile au premier passage du trait (format du calque).
    var originals: [TileCoord: [UInt8]] = [:]

    public init() {}

    public var touchedTiles: Set<TileCoord> { Set(originals.keys) }

    /// Masque d'un texel (zéro hors du trait) : pour les tests.
    public func mask(at coord: TileCoord, index: Int) -> SIMD4<Float> {
        masks[coord].map { Self.widen($0[index]) } ?? .zero
    }

    @inline(__always)
    static func widen(_ v: SIMD4<Float16>) -> SIMD4<Float> {
        SIMD4<Float>(Float(v.x), Float(v.y), Float(v.z), Float(v.w))
    }

    @inline(__always)
    static func narrow(_ v: SIMD4<Float>) -> SIMD4<Float16> {
        SIMD4<Float16>(Float16(v.x), Float16(v.y), Float16(v.z), Float16(v.w))
    }
}
