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
        let h = Double(height)

        let y0 = Int(floor((Double.pi / 2 - min(top, .pi / 2)) / .pi * h))
        let y1 = Int(ceil((Double.pi / 2 - max(bottom, -.pi / 2)) / .pi * h))
        rows = max(0, y0)...min(height - 1, y1)

        let full = [0...(width - 1)]
        let s = sin(radius) / cos(lat0)
        guard top < .pi / 2, bottom > -.pi / 2, s < 1 else {
            columns = full
            return
        }
        let dLon = asin(s)
        let w = Double(width)
        let x0 = Int(floor(((lon0 - dLon) / (2 * .pi) + 0.5) * w)) - 1
        let x1 = Int(ceil(((lon0 + dLon) / (2 * .pi) + 0.5) * w)) + 1
        guard x1 - x0 + 1 < width else {
            columns = full
            return
        }
        let start = ((x0 % width) + width) % width
        let end = start + (x1 - x0)
        columns = end < width ? [start...end] : [start...(width - 1), 0...(end - width)]
    }
}
