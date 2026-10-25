import Foundation

/// Rectangle(s) de texels équirectangulaires qu'un dab peut toucher. Les colonnes bouclent sur la couture.
public struct EquirectSpan: Equatable, Sendable {
    public var rows: ClosedRange<Int>
    /// Une plage, deux si le dab chevauche la couture, ou toute la rangée.
    public var columns: [ClosedRange<Int>]

    public init(rows: ClosedRange<Int>, columns: [ClosedRange<Int>]) {
        self.rows = rows
        self.columns = columns
    }

    /// Zone touchée par une calotte de rayon angulaire `radius` centrée sur `center`.
    /// Bande de latitude ±r ; demi-largeur en longitude asin(sin r / cos lat) ; rangées entières si la calotte englobe un pôle.
    public init(center: Vec3, radius: Double, width: Int, height: Int) {
        let lat0 = Equirect.latitude(of: center)
        let lon0 = Equirect.longitude(of: center)
        let top = lat0 + radius
        let bottom = lat0 - radius
        let halfPi: Double = .pi / 2
        let rowsPerRadian: Double = Double(height) / .pi
        let columnsPerRadian: Double = Double(width) / (2 * .pi)

        let vTop: Double = (halfPi - min(top, halfPi)) * rowsPerRadian
        let vBottom: Double = (halfPi - max(bottom, -halfPi)) * rowsPerRadian
        rows = max(0, Int(floor(vTop)))...min(height - 1, Int(ceil(vBottom)))

        let full = [0...(width - 1)]
        let s: Double = sin(radius) / cos(lat0)
        guard top < halfPi, bottom > -halfPi, s < 1 else {
            columns = full
            return
        }
        let dLon: Double = asin(s)
        let halfWidth: Double = Double(width) / 2
        let uMin: Double = (lon0 - dLon) * columnsPerRadian + halfWidth
        let uMax: Double = (lon0 + dLon) * columnsPerRadian + halfWidth
        let x0 = Int(floor(uMin)) - 1
        let x1 = Int(ceil(uMax)) + 1
        guard x1 - x0 + 1 < width else {
            columns = full
            return
        }
        let start = ((x0 % width) + width) % width
        let end = start + (x1 - x0)
        columns = end < width ? [start...end] : [start...(width - 1), 0...(end - width)]
    }
}
