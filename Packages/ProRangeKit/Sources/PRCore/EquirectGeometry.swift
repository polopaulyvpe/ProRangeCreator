import simd

/// Géométrie d'une toile équirectangulaire : directions des centres de texels, précalculées par rangée et par colonne.
/// Partagée par la toile CPU de référence et les calques tuilés, pour que les deux calculent exactement les mêmes directions.
public struct EquirectGeometry: Sendable {
    public let width: Int
    public let height: Int

    private let rowSin: [Double]
    private let rowCos: [Double]
    private let colSin: [Double]
    private let colCos: [Double]

    public init(width: Int, height: Int) {
        precondition(width == 2 * height, "ratio 2:1 obligatoire")
        self.width = width
        self.height = height
        let rowStep: Double = .pi / Double(height)
        let columnStep: Double = 2 * .pi / Double(width)
        let thetas: [Double] = (0..<height).map { y in (Double(y) + 0.5) * rowStep }
        let phis: [Double] = (0..<width).map { x in (Double(x) + 0.5) * columnStep - .pi }
        rowSin = thetas.map(sin)
        rowCos = thetas.map(cos)
        colSin = phis.map(sin)
        colCos = phis.map(cos)
    }

    /// Identique à `Equirect.direction(x:y:width:height:)`.
    @inline(__always)
    public func direction(x: Int, y: Int) -> Vec3 {
        [rowSin[y] * colSin[x], rowCos[y], -rowSin[y] * colCos[x]]
    }

    /// Pas angulaire d'une rangée de texels.
    public var pixelAngle: Double { .pi / Double(height) }

    /// Angle solide (stéradians) d'un texel de la rangée `y`.
    public func texelSolidAngle(row y: Int) -> Double {
        let t0: Double = Double(y) / Double(height) * .pi
        let t1: Double = Double(y + 1) / Double(height) * .pi
        return 2 * .pi / Double(width) * (cos(t0) - cos(t1))
    }
}

/// Évalue la couverture d'un dab en n'importe quelle direction. Même calcul pour toutes les cibles (toile CPU, tuiles, futur kernel Metal).
public struct DabEvaluator: Sendable {
    public let dab: SphericalDab
    public let frame: TangentFrame
    public let pixelAngle: Double
    /// Rayon au-delà duquel la couverture est nulle (rayon + un texel de marge).
    public let reach: Double
    private let cosReach: Double

    public init(_ dab: SphericalDab, pixelAngle: Double) {
        self.dab = dab
        self.frame = TangentFrame(center: dab.center)
        self.pixelAngle = pixelAngle
        // Une forme occupe le carré circonscrit au disque : sa portée va jusqu'aux coins.
        let extent = dab.tip?.shape != nil ? dab.radius * 2.0.squareRoot() : dab.radius
        self.reach = extent + pixelAngle
        self.cosReach = cos(reach)
    }

    /// Zone de texels à parcourir sur une toile de cette géométrie.
    public func span(in geometry: EquirectGeometry) -> EquirectSpan {
        EquirectSpan(center: frame.center, radius: reach, width: geometry.width, height: geometry.height)
    }

    @inline(__always)
    public func coverage(at d: Vec3) -> Float {
        if simd_dot(d, frame.center) < cosReach { return 0 }
        let p = frame.project(d)
        guard let tip = dab.tip else {
            return Float(SphericalRasterizer.coverage(distance: simd_length(p), radius: dab.radius,
                                                      hardness: dab.hardness, pixelSize: pixelAngle))
        }
        let base = tip.shapeValue(at: p, radius: dab.radius)
            ?? Float(SphericalRasterizer.coverage(distance: simd_length(p), radius: dab.radius,
                                                  hardness: dab.hardness, pixelSize: pixelAngle))
        guard base > 0, tip.grain != nil else { return base }
        return base * (1 - Float(tip.grainDepth) * (1 - tip.grainValue(at: d, local: p)))
    }
}
