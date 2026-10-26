import Foundation

/// Pinceau ou tampon fourni avec l'app : formes et grains générés par calcul (aucun contenu protégé),
/// déterministes d'une exécution à l'autre.
public struct BuiltInBrush: Sendable, Identifiable {
    public let category: String
    public let name: String
    public let settings: BrushSettings
    public var id: String { "\(category)/\(name)" }
}

public enum BuiltInBrushes {
    public static let categories = ["Nuages", "Ciel nocturne", "Atmosphère", "Végétation", "Tampons"]

    /// Générés une fois, au premier accès.
    public static let all: [BuiltInBrush] = make()

    /// Substitut des formes internes de Procreate (non incluses dans les .brush) : tache ronde granuleuse.
    public static let substituteShape: BrushTexture = shape("Substitut granuleux") { x, y in
        let d = (x * x + y * y).squareRoot()
        let disc = 1 - smoothstep(0.55, 0.95, d)
        let speckle = smoothstep(0.35, 0.65, fbm(x * 4 + 7, y * 4 + 7, octaves: 4, period: 64, seed: 101))
        return disc * (0.35 + 0.65 * speckle)
    }

    /// Substitut des grains internes de Procreate : grain de papier raccordable.
    public static let substituteGrain: BrushTexture = grain("Substitut de grain") { u, v in
        0.35 + 0.9 * (fbm(u * 16, v * 16, octaves: 4, period: 16, seed: 202) - 0.3)
    }

    // MARK: - Bruit

    /// Hachage entier → [0, 1).
    private static func hash(_ x: Int, _ y: Int, _ seed: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263 &+ seed &* 1_442_695_041)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFFFF) / Float(0x1000000)
    }

    /// Bruit de valeur 2D lissé, périodique de période `period` (pour des grains raccordables).
    private static func noise(_ x: Float, _ y: Float, period: Int, seed: Int) -> Float {
        let xi = Int(floor(x)), yi = Int(floor(y))
        let fx = x - Float(xi), fy = y - Float(yi)
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        func h(_ i: Int, _ j: Int) -> Float {
            hash(((i % period) + period) % period, ((j % period) + period) % period, seed)
        }
        let top = h(xi, yi) * (1 - sx) + h(xi + 1, yi) * sx
        let bottom = h(xi, yi + 1) * (1 - sx) + h(xi + 1, yi + 1) * sx
        return top * (1 - sy) + bottom * sy
    }

    /// Somme d'octaves dans [0, 1].
    private static func fbm(_ x: Float, _ y: Float, octaves: Int = 4, period: Int = 8, seed: Int = 1) -> Float {
        var sum: Float = 0, amplitude: Float = 0.5, total: Float = 0
        var frequency: Float = 1, p = period
        for o in 0..<octaves {
            sum += amplitude * noise(x * frequency, y * frequency, period: p, seed: seed + o * 17)
            total += amplitude
            amplitude *= 0.5
            frequency *= 2
            p *= 2
        }
        return sum / total
    }

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// Texture carrée : `f(x, y)` avec x vers la droite et y vers le haut dans [-1, 1].
    private static func shape(_ name: String, size: Int = 256, _ f: (Float, Float) -> Float) -> BrushTexture {
        var values = [Float](repeating: 0, count: size * size)
        for row in 0..<size {
            let y = 1 - 2 * (Float(row) + 0.5) / Float(size)
            for column in 0..<size {
                let x = 2 * (Float(column) + 0.5) / Float(size) - 1
                values[row * size + column] = min(1, max(0, f(x, y)))
            }
        }
        return BrushTexture(name: name, size: size, values: values)
    }

    /// Grain raccordable : `f(u, v)` avec u, v dans [0, 1).
    private static func grain(_ name: String, size: Int = 256, _ f: (Float, Float) -> Float) -> BrushTexture {
        var values = [Float](repeating: 0, count: size * size)
        for row in 0..<size {
            for column in 0..<size {
                values[row * size + column] = min(1, max(0, f(Float(column) / Float(size), Float(row) / Float(size))))
            }
        }
        return BrushTexture(name: name, size: size, values: values)
    }

    private static func brush(radius: Double, opacity: Double = 1, hardness: Double = 0.8, spacing: Double, pressureSize: Bool = true,
                              pressureOpacity: Bool = false, shape: BrushTexture? = nil, grain: BrushTexture? = nil,
                              follow: Bool = false, grainScale: Double = 3, grainDepth: Double = 1) -> BrushSettings {
        var s = BrushSettings(radiusDegrees: radius, opacity: opacity, hardness: hardness, spacing: spacing,
                              pressureAffectsSize: pressureSize, pressureAffectsOpacity: pressureOpacity, minimumSize: 0.3)
        s.shape = shape
        s.grain = grain
        s.followStroke = follow
        s.grainScaleDegrees = grainScale
        s.grainDepth = grainDepth
        return s
    }

    // MARK: - Catalogue

    private static func make() -> [BuiltInBrush] {
        let cloudGrain = grain("Grain nuageux") { u, v in fbm(u * 8, v * 8, octaves: 5, period: 8, seed: 3) * 1.4 - 0.15 }
        let fineGrain = grain("Grain fin") { u, v in 0.55 + 0.9 * (fbm(u * 32, v * 32, octaves: 3, period: 32, seed: 9) - 0.5) }

        let cumulus = shape("Cumulus") { x, y in
            let blobs: [(Float, Float, Float)] = [(-0.42, -0.05, 0.42), (-0.05, 0.2, 0.55), (0.4, 0.02, 0.45), (0.1, -0.2, 0.5), (-0.25, 0.32, 0.3)]
            var v: Float = 0
            for (cx, cy, r) in blobs {
                let d = ((x - cx) * (x - cx) + (y - cy) * (y - cy)).squareRoot() / r
                v = max(v, 1 - smoothstep(0.55, 1, d))
            }
            let base = smoothstep(-0.55, -0.3, y) // dessous plus plat
            return v * base * (0.65 + 0.5 * fbm(x * 3 + 5, y * 3 + 5, period: 64, seed: 4))
        }
        let stratus = shape("Stratus") { x, y in
            let e = (x * x / 0.9 + y * y / 0.07).squareRoot()
            return (1 - smoothstep(0.4, 1, e)) * (0.45 + 0.7 * fbm(x * 2 + 9, y * 9, period: 64, seed: 6))
        }
        let cirrus = shape("Cirrus") { x, y in
            let bend = y - 0.25 * x * x
            let streak = fbm(x * 1.2 + 3, bend * 10, octaves: 4, period: 64, seed: 12)
            let envelope = 1 - smoothstep(0.5, 1, (x * x / 0.95 + bend * bend / 0.2).squareRoot())
            return smoothstep(0.45, 0.75, streak) * envelope
        }
        let stars = shape("Étoiles") { x, y in
            var v: Float = 0
            for i in 0..<16 {
                let cx = hash(i, 1, 21) * 1.7 - 0.85, cy = hash(i, 2, 21) * 1.7 - 0.85
                let r = 0.015 + 0.05 * pow(hash(i, 3, 21), 3)
                let brightness = 0.35 + 0.65 * hash(i, 4, 21)
                let d2 = ((x - cx) * (x - cx) + (y - cy) * (y - cy)) / (r * r)
                v = max(v, brightness * exp(-d2))
            }
            return v
        }
        let rays = shape("Rayons") { x, y in
            let beam = exp(-(y * y) / 0.02)
            let ends = smoothstep(-1, -0.6, x) * (1 - smoothstep(0.6, 1, x))
            return beam * ends * (0.6 + 0.5 * fbm(x * 4, 0.5, period: 64, seed: 30))
        }
        let sparkle = shape("Étincelle") { x, y in
            let ax = abs(x), ay = abs(y)
            let horizontal: Float = exp(-ax / 0.025) * exp(-ay / 0.35)
            let vertical: Float = exp(-ay / 0.025) * exp(-ax / 0.35)
            let cross = max(horizontal, vertical)
            let r2: Float = x * x + y * y
            let core: Float = exp(-r2 / 0.01)
            return cross + core
        }
        let foliage = shape("Feuillage") { x, y in
            var v: Float = 0
            for i in 0..<22 {
                let cx = hash(i, 5, 40) * 1.4 - 0.7, cy = hash(i, 6, 40) * 1.4 - 0.7
                let angle = hash(i, 7, 40) * .pi
                let c = cos(angle), s = sin(angle)
                let lx = ((x - cx) * c + (y - cy) * s) / 0.22, ly = (-(x - cx) * s + (y - cy) * c) / 0.09
                if lx * lx + ly * ly < 1 { v = max(v, 0.6 + 0.4 * hash(i, 8, 40)) }
            }
            return v
        }
        let grass = shape("Herbe") { x, y in
            var v: Float = 0
            for i in 0..<20 {
                let base = hash(i, 9, 50) * 1.8 - 0.9
                let height = 0.6 + 1.2 * hash(i, 10, 50)
                let lean = (hash(i, 11, 50) - 0.5) * 0.6
                let t = (y + 1) / height // 0 au pied, 1 à la pointe
                guard t >= 0, t <= 1 else { continue }
                let center = base + lean * t * t
                let half = 0.035 * (1 - t)
                if abs(x - center) < half { v = max(v, 0.7 + 0.3 * hash(i, 12, 50)) }
            }
            return v
        }
        let sun = shape("Soleil") { x, y in
            let d = (x * x + y * y).squareRoot()
            return (1 - smoothstep(0.3, 0.34, d)) + 0.5 * exp(-d * d / 0.15)
        }
        let moon = shape("Lune") { x, y in
            let d = (x * x + y * y).squareRoot()
            let disk = 1 - smoothstep(0.6, 0.63, d)
            let craters = 0.78 + 0.22 * fbm(x * 3 + 1, y * 3 + 1, octaves: 5, period: 64, seed: 60)
            return disk * craters
        }
        let hills = shape("Collines") { x, y in
            let wave1: Float = 0.22 * sin(x * 2.1 + 0.4)
            let wave2: Float = 0.1 * sin(x * 5.3 + 1.7)
            let detail: Float = 0.05 * (fbm(x * 4 + 2, 0.3, period: 64, seed: 70) - 0.5)
            let ridge: Float = -0.15 + wave1 + wave2 + detail
            return 1 - smoothstep(ridge - 0.01, ridge + 0.01, y)
        }
        let pines = shape("Pins") { x, y in
            if y < -0.75 { return 1 }
            var v: Float = 0
            for i in 0..<9 {
                let cx = -0.9 + Float(i) * 0.225 + (hash(i, 13, 80) - 0.5) * 0.1
                let top = -0.2 + 0.7 * hash(i, 14, 80)
                let width = 0.09 + 0.05 * hash(i, 15, 80)
                guard y <= top, y >= -0.8 else { continue }
                let t = (top - y) / (top + 0.8) // 0 en haut, 1 au pied
                // Trois étages en dents de scie.
                let tier = t * 3 - floor(t * 3)
                let half = width * (0.35 + 0.65 * t) * (0.55 + 0.45 * tier)
                if abs(x - cx) < half || (abs(x - cx) < 0.012 && y < -0.65) { v = 1 }
            }
            return v
        }
        let buildings = shape("Bâtiments") { x, y in
            if y < -0.85 { return 1 }
            var left: Float = -1
            var i = 0
            while left < 1 {
                let width = 0.1 + 0.15 * hash(i, 16, 90)
                let top = -0.6 + 1.1 * pow(hash(i, 17, 90), 1.5)
                if x >= left, x < left + width, y <= top { return 1 }
                left += width + 0.01
                i += 1
            }
            return 0
        }

        return [
            BuiltInBrush(category: "Nuages", name: "Cumulus", settings: brush(radius: 6, opacity: 0.9, spacing: 0.35, shape: cumulus, grain: cloudGrain, grainScale: 8, grainDepth: 0.5)),
            BuiltInBrush(category: "Nuages", name: "Stratus", settings: brush(radius: 8, opacity: 0.6, spacing: 0.25, pressureOpacity: true, shape: stratus, follow: true)),
            BuiltInBrush(category: "Nuages", name: "Cirrus", settings: brush(radius: 7, opacity: 0.7, spacing: 0.3, shape: cirrus, follow: true)),
            BuiltInBrush(category: "Ciel nocturne", name: "Étoiles", settings: brush(radius: 4, spacing: 1.6, pressureSize: false, shape: stars)),
            BuiltInBrush(category: "Ciel nocturne", name: "Étoile seule", settings: brush(radius: 0.4, hardness: 0.2, spacing: 3, pressureSize: true)),
            BuiltInBrush(category: "Atmosphère", name: "Brume", settings: brush(radius: 12, opacity: 0.12, hardness: 0, spacing: 0.15, pressureOpacity: true, grain: cloudGrain, grainScale: 15, grainDepth: 0.6)),
            BuiltInBrush(category: "Atmosphère", name: "Rayons", settings: brush(radius: 10, opacity: 0.35, spacing: 0.2, shape: rays, follow: true)),
            BuiltInBrush(category: "Atmosphère", name: "Étincelles", settings: brush(radius: 1.5, spacing: 2.5, shape: sparkle)),
            BuiltInBrush(category: "Atmosphère", name: "Craie", settings: brush(radius: 1.5, opacity: 0.9, hardness: 0.6, spacing: 0.12, grain: fineGrain, grainScale: 1.5, grainDepth: 0.9)),
            BuiltInBrush(category: "Végétation", name: "Feuillage", settings: brush(radius: 3, spacing: 0.6, shape: foliage)),
            BuiltInBrush(category: "Végétation", name: "Herbe", settings: brush(radius: 2.5, spacing: 0.5, shape: grass)),
            BuiltInBrush(category: "Tampons", name: "Soleil", settings: brush(radius: 4, spacing: 20, pressureSize: false, shape: sun)),
            BuiltInBrush(category: "Tampons", name: "Lune", settings: brush(radius: 3, spacing: 20, pressureSize: false, shape: moon)),
            BuiltInBrush(category: "Tampons", name: "Collines", settings: brush(radius: 20, spacing: 20, pressureSize: false, shape: hills)),
            BuiltInBrush(category: "Tampons", name: "Pins", settings: brush(radius: 12, spacing: 20, pressureSize: false, shape: pines)),
            BuiltInBrush(category: "Tampons", name: "Bâtiments", settings: brush(radius: 14, spacing: 20, pressureSize: false, shape: buildings)),
        ]
    }
}
