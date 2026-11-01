import Foundation

/// Pack de pinceaux de dessin et de peinture fourni avec l'app : les familles attendues dans toute app de dessin
/// (croquis, encrage, peinture, aérographe, techniques sèches, effets). Noms, formes et grains sont les nôtres,
/// générés par calcul : rien n'est repris de Procreate ni d'une autre app.
extension BuiltInBrushes {
    static let drawingCategories = ["Croquis", "Encrage", "Peinture", "Aérographe", "Techniques sèches", "Effets"]

    /// Réglages de départ d'un pinceau du pack, ajustés par `edit`.
    private static func preset(radius: Double, hardness: Double = 0.8, spacing: Double, opacity: Double = 1,
                               _ edit: (inout BrushSettings) -> Void) -> BrushSettings {
        var s = BrushSettings(radiusDegrees: radius, opacity: opacity, hardness: hardness, spacing: spacing,
                              pressureAffectsSize: true, pressureAffectsOpacity: false, minimumSize: 0)
        edit(&s)
        s.refreshGrain()
        return s
    }

    /// Grain : image source et grain dérivé (contraste, luminosité).
    private static func setGrain(_ s: inout BrushSettings, _ texture: BrushTexture, scale: Double, depth: Double,
                                 moving: Bool = false, blend: DualBlendMode = .multiply) {
        s.grainSource = texture
        s.grainScaleDegrees = scale
        s.grainDepth = depth
        s.grainMoving = moving
        s.grainBlendMode = blend
    }

    static func drawingPack() -> [BuiltInBrush] {
        // MARK: Grains (raccordables)
        let paper = grain("Papier à dessin") { u, v in
            let fine = fbm(u * 48, v * 48, octaves: 3, period: 48, seed: 301)
            let tooth = fbm(u * 12, v * 12, octaves: 3, period: 12, seed: 302)
            return 0.25 + 1.1 * (0.6 * fine + 0.4 * tooth) - 0.15
        }
        let roughPaper = grain("Papier torchon") { u, v in
            let pits = smoothstep(0.32, 0.55, fbm(u * 10, v * 10, octaves: 4, period: 10, seed: 311))
            return pits * (0.55 + 0.6 * fbm(u * 40, v * 40, octaves: 2, period: 40, seed: 312))
        }
        let wax = grain("Cire") { u, v in
            let streak = fbm(u * 6, v * 40, octaves: 3, period: 6, seed: 321)
            return smoothstep(0.3, 0.62, streak) * 0.85 + 0.1 * fbm(u * 50, v * 50, octaves: 2, period: 50, seed: 322)
        }
        let canvas = grain("Toile") { u, v in
            let weave = (sin(u * 2 * .pi * 24) * sin(v * 2 * .pi * 24) + 1) * 0.5
            return 0.45 + 0.35 * weave + 0.25 * (fbm(u * 24, v * 24, octaves: 2, period: 24, seed: 331) - 0.5)
        }
        let speckle = grain("Moucheture") { u, v in
            smoothstep(0.45, 0.7, fbm(u * 30, v * 30, octaves: 3, period: 30, seed: 341))
        }

        // MARK: Formes
        let charcoal = shape("Bâton de fusain") { x, y in
            let wobble = 0.12 * (fbm(x * 3 + 2, y * 3 + 2, octaves: 3, period: 64, seed: 351) - 0.5)
            let d = (x * x / 0.75 + y * y).squareRoot() + wobble
            let edge = 1 - smoothstep(0.7, 0.95, d)
            return edge * (0.55 + 0.6 * fbm(x * 9 + 4, y * 9 + 4, octaves: 3, period: 64, seed: 352))
        }
        let roundBristles = shape("Poils ronds") { x, y in
            let r = (x * x + y * y).squareRoot()
            let a = atan2(y, x)
            let hairs = fbm(cos(a) * 6 + 10, sin(a) * 6 + 10, octaves: 3, period: 64, seed: 361)
            return (1 - smoothstep(0.6, 0.95, r)) * (0.55 + 0.6 * hairs)
        }
        // Brosse plate : largeur en travers du trait (y), poils le long du trait (x), avec la forme qui suit le trait.
        let flatBristles = shape("Brosse plate") { x, y in
            let body = (1 - smoothstep(0.7, 0.92, abs(y))) * (1 - smoothstep(0.18, 0.32, abs(x)))
            let hairs = smoothstep(0.3, 0.62, fbm(3, y * 28 + 3, octaves: 3, period: 64, seed: 371))
            return body * (0.35 + 0.75 * hairs)
        }
        let oilBristles = shape("Brosse à huile") { x, y in
            let body = (1 - smoothstep(0.62, 0.9, abs(y))) * (1 - smoothstep(0.25, 0.45, abs(x)))
            let hairs = smoothstep(0.25, 0.7, fbm(x * 2 + 5, y * 20 + 5, octaves: 4, period: 64, seed: 381))
            return body * (0.4 + 0.7 * hairs)
        }
        // Aquarelle : tache au bord plus foncé (le pigment s'accumule au bord en séchant).
        let watercolor = shape("Tache d'aquarelle") { x, y in
            let wobble = 0.1 * (fbm(x * 2.5 + 1, y * 2.5 + 1, octaves: 3, period: 64, seed: 391) - 0.5)
            let d = (x * x + y * y).squareRoot() + wobble
            let inside = 1 - smoothstep(0.82, 0.9, d)
            let rim = smoothstep(0.55, 0.85, d)
            return inside * (0.45 + 0.45 * rim + 0.15 * fbm(x * 6 + 8, y * 6 + 8, octaves: 2, period: 64, seed: 392))
        }
        let knife = shape("Couteau") { x, y in
            let body = (1 - smoothstep(0.82, 0.95, abs(y))) * (1 - smoothstep(0.12, 0.2, abs(x)))
            let drag = 0.7 + 0.35 * fbm(9, y * 14 + 9, octaves: 3, period: 64, seed: 401)
            return body * drag
        }
        let spatter = shape("Éclaboussures") { x, y in
            var v: Float = 0
            for i in 0..<22 {
                let cx = hash(i, 1, 411) * 1.8 - 0.9, cy = hash(i, 2, 411) * 1.8 - 0.9
                let r = 0.025 + 0.11 * pow(hash(i, 3, 411), 2.5)
                let d = ((x - cx) * (x - cx) + (y - cy) * (y - cy)).squareRoot()
                v = max(v, 1 - smoothstep(r * 0.75, r, d))
            }
            return v
        }
        let sponge = shape("Éponge") { x, y in
            let disc = 1 - smoothstep(0.7, 0.95, (x * x + y * y).squareRoot())
            let holes = smoothstep(0.38, 0.5, fbm(x * 5 + 3, y * 5 + 3, octaves: 4, period: 64, seed: 421))
            return disc * holes
        }
        let pastelStick = shape("Bâton de pastel") { x, y in
            let body = (1 - smoothstep(0.75, 0.95, abs(y))) * (1 - smoothstep(0.45, 0.7, abs(x)))
            return body * (0.5 + 0.6 * fbm(x * 7 + 6, y * 7 + 6, octaves: 3, period: 64, seed: 431))
        }

        // Courbes de pression courantes.
        let soft = PressureCurve(points: [[0, 0], [0.35, 0.5], [1, 1]])
        let firm = PressureCurve(points: [[0, 0], [0.6, 0.4], [1, 1]])

        return [
            // MARK: Croquis
            BuiltInBrush(category: "Croquis", name: "Crayon HB", settings: preset(radius: 0.3, hardness: 0.7, spacing: 0.08, opacity: 0.85) { s in
                s.name = "Crayon HB"
                setGrain(&s, paper, scale: 1.2, depth: 0.85)
                s.pressureAffectsOpacity = true
                s.pressureOpacityAmount = 0.7
                s.pressureSizeAmount = 0.5
                s.rendering = .intenseGlaze
                s.flow = 0.6
                s.tiltSize = 2
                s.tiltOpacity = 0.4
                s.tiltAngleDegrees = 35
                s.streamLine = 0.1
                s.pressureCurve = soft
            }),
            BuiltInBrush(category: "Croquis", name: "Crayon gras 6B", settings: preset(radius: 0.55, hardness: 0.5, spacing: 0.08, opacity: 0.95) { s in
                s.name = "Crayon gras 6B"
                setGrain(&s, roughPaper, scale: 1.6, depth: 0.9)
                s.pressureAffectsOpacity = true
                s.pressureOpacityAmount = 0.8
                s.pressureSizeAmount = 0.4
                s.rendering = .intenseGlaze
                s.flow = 0.7
                s.tiltSize = 2.5
                s.tiltOpacity = 0.5
                s.tiltAngleDegrees = 30
                s.pressureCurve = soft
            }),
            BuiltInBrush(category: "Croquis", name: "Mine fine", settings: preset(radius: 0.14, hardness: 0.95, spacing: 0.06, opacity: 0.9) { s in
                s.name = "Mine fine"
                setGrain(&s, paper, scale: 1, depth: 0.5)
                s.pressureAffectsOpacity = true
                s.pressureOpacityAmount = 0.6
                s.pressureSizeAmount = 0.3
                s.streamLine = 0.15
            }),
            BuiltInBrush(category: "Croquis", name: "Crayon de couleur", settings: preset(radius: 0.4, hardness: 0.6, spacing: 0.08, opacity: 0.9) { s in
                s.name = "Crayon de couleur"
                setGrain(&s, wax, scale: 1.4, depth: 0.8)
                s.pressureAffectsOpacity = true
                s.pressureOpacityAmount = 0.75
                s.pressureSizeAmount = 0.35
                s.rendering = .intenseGlaze
                s.flow = 0.55
                s.tiltSize = 1.5
                s.tiltAngleDegrees = 35
            }),
            BuiltInBrush(category: "Croquis", name: "Esquisse rapide", settings: preset(radius: 0.25, hardness: 0.8, spacing: 0.08, opacity: 0.6) { s in
                s.name = "Esquisse rapide"
                setGrain(&s, paper, scale: 1.2, depth: 0.6)
                s.pressureAffectsOpacity = true
                s.pressureOpacityAmount = 0.9
                s.rendering = .intenseGlaze
                s.flow = 0.5
                s.taperStartLength = 1.5
                s.taperEndLength = 2
                s.taperSize = 0.6
                s.taperOpacity = 0.6
            }),

            // MARK: Encrage
            BuiltInBrush(category: "Encrage", name: "Plume", settings: preset(radius: 0.6, hardness: 1, spacing: 0.04) { s in
                s.name = "Plume"
                s.pressureSizeAmount = 1
                s.taperStartLength = 2
                s.taperEndLength = 3
                s.taperSize = 0.9
                s.streamLine = 0.25
                s.pressureCurve = soft
            }),
            BuiltInBrush(category: "Encrage", name: "Feutre fin", settings: preset(radius: 0.18, hardness: 1, spacing: 0.04) { s in
                s.name = "Feutre fin"
                s.pressureAffectsSize = false
                s.streamLine = 0.3
                s.stabilization = 0.1
            }),
            BuiltInBrush(category: "Encrage", name: "Stylo bille", settings: preset(radius: 0.12, hardness: 1, spacing: 0.05, opacity: 0.95) { s in
                s.name = "Stylo bille"
                s.pressureSizeAmount = 0.25
                s.pressureAffectsOpacity = true
                s.pressureOpacityAmount = 0.5
                s.streamLine = 0.15
            }),
            BuiltInBrush(category: "Encrage", name: "Pinceau à encre", settings: preset(radius: 1.2, hardness: 0.95, spacing: 0.03) { s in
                s.name = "Pinceau à encre"
                s.pressureSizeAmount = 1
                s.pressureCurve = firm
                s.taperStartLength = 3
                s.taperEndLength = 5
                s.taperSize = 1
                s.shape = shape("Pointe de pinceau") { x, y in 1 - smoothstep(0.85, 0.98, (x * x + y * y / 0.55).squareRoot()) }
                s.shapeRoundness = 0.7
                s.followStroke = true
                s.streamLine = 0.3
            }),
            BuiltInBrush(category: "Encrage", name: "Encre sèche", settings: preset(radius: 0.7, hardness: 0.9, spacing: 0.05) { s in
                s.name = "Encre sèche"
                setGrain(&s, roughPaper, scale: 2, depth: 0.9, moving: false, blend: .linearBurn)
                s.grainContrast = 0.3
                s.pressureSizeAmount = 0.8
                s.taperEndLength = 2
                s.taperSize = 0.7
                s.pressureCurve = firm
            }),

            // MARK: Peinture
            BuiltInBrush(category: "Peinture", name: "Pinceau rond", settings: preset(radius: 2, hardness: 0.55, spacing: 0.06, opacity: 0.9) { s in
                s.name = "Pinceau rond"
                s.shape = roundBristles
                s.pressureSizeAmount = 0.7
                s.pressureAffectsOpacity = true
                s.pressureOpacityAmount = 0.4
                s.flow = 0.7
                s.pressureFlowAmount = 0.5
                s.rotationJitter = .pi
            }),
            BuiltInBrush(category: "Peinture", name: "Brosse plate", settings: preset(radius: 2.5, hardness: 0.8, spacing: 0.03, opacity: 0.95) { s in
                s.name = "Brosse plate"
                s.shape = flatBristles
                s.followStroke = true
                s.shapeRotationDegrees = 90
                s.pressureSizeAmount = 0.4
                s.flow = 0.8
                s.pressureFlowAmount = 0.6
                setGrain(&s, canvas, scale: 2, depth: 0.3)
            }),
            BuiltInBrush(category: "Peinture", name: "Huile", settings: preset(radius: 2.5, hardness: 0.8, spacing: 0.03) { s in
                s.name = "Huile"
                s.shape = oilBristles
                s.followStroke = true
                s.shapeRotationDegrees = 90
                s.rendering = .intenseGlaze
                s.flow = 0.45
                s.pressureFlowAmount = 0.7
                s.pressureSizeAmount = 0.5
                s.sizeJitter = 0.1
                setGrain(&s, canvas, scale: 2.5, depth: 0.45)
            }),
            BuiltInBrush(category: "Peinture", name: "Gouache", settings: preset(radius: 3, hardness: 0.65, spacing: 0.05) { s in
                s.name = "Gouache"
                s.shape = roundBristles
                s.rotationJitter = .pi
                s.pressureSizeAmount = 0.5
                s.flow = 0.85
                s.pressureFlowAmount = 0.4
                setGrain(&s, paper, scale: 3, depth: 0.25)
            }),
            BuiltInBrush(category: "Peinture", name: "Aquarelle", settings: preset(radius: 4, hardness: 0.3, spacing: 0.08, opacity: 0.4) { s in
                s.name = "Aquarelle"
                s.shape = watercolor
                s.rotationJitter = .pi
                s.sizeJitter = 0.15
                s.rendering = .uniformGlaze
                s.flow = 0.5
                s.pressureAffectsOpacity = true
                s.pressureOpacityAmount = 0.6
                s.pressureSizeAmount = 0.4
                setGrain(&s, roughPaper, scale: 4, depth: 0.45)
            }),
            BuiltInBrush(category: "Peinture", name: "Couteau", settings: preset(radius: 2.2, hardness: 1, spacing: 0.02) { s in
                s.name = "Couteau"
                s.shape = knife
                s.followStroke = true
                s.shapeRotationDegrees = 90
                s.pressureAffectsSize = false
                s.flow = 1
                setGrain(&s, canvas, scale: 2.5, depth: 0.55, blend: .linearBurn)
            }),

            // MARK: Aérographe
            BuiltInBrush(category: "Aérographe", name: "Aérographe moyen", settings: preset(radius: 4, hardness: 0.4, spacing: 0.08, opacity: 0.5) { s in
                s.name = "Aérographe moyen"
                s.pressureAffectsSize = false
                s.pressureAffectsOpacity = true
                s.pressureOpacityAmount = 1
                s.rendering = .intenseGlaze
                s.flow = 0.15
            }),
            BuiltInBrush(category: "Aérographe", name: "Aérographe dur", settings: preset(radius: 3, hardness: 0.85, spacing: 0.06, opacity: 0.8) { s in
                s.name = "Aérographe dur"
                s.pressureAffectsSize = false
                s.pressureAffectsOpacity = true
                s.pressureOpacityAmount = 1
                s.flow = 0.4
            }),
            BuiltInBrush(category: "Aérographe", name: "Aérographe texturé", settings: preset(radius: 5, hardness: 0.2, spacing: 0.1, opacity: 0.45) { s in
                s.name = "Aérographe texturé"
                s.pressureAffectsSize = false
                s.pressureAffectsOpacity = true
                s.pressureOpacityAmount = 1
                s.rendering = .intenseGlaze
                s.flow = 0.15
                setGrain(&s, speckle, scale: 2.5, depth: 0.85)
            }),
            BuiltInBrush(category: "Aérographe", name: "Éclaboussures", settings: preset(radius: 3, hardness: 1, spacing: 1.2) { s in
                s.name = "Éclaboussures"
                s.shape = spatter
                s.pressureSizeAmount = 0.5
                s.rotationJitter = .pi
                s.randomFlip = true
                s.sizeJitter = 0.5
                s.scatter = 0.6
            }),

            // MARK: Techniques sèches
            BuiltInBrush(category: "Techniques sèches", name: "Fusain", settings: preset(radius: 0.9, hardness: 0.6, spacing: 0.06, opacity: 0.95) { s in
                s.name = "Fusain"
                s.shape = charcoal
                s.rotationJitter = .pi
                setGrain(&s, roughPaper, scale: 1.8, depth: 0.95)
                s.pressureAffectsOpacity = true
                s.pressureOpacityAmount = 0.7
                s.pressureSizeAmount = 0.3
                s.rendering = .intenseGlaze
                s.flow = 0.6
                s.tiltSize = 2
                s.tiltAngleDegrees = 30
            }),
            BuiltInBrush(category: "Techniques sèches", name: "Pastel sec", settings: preset(radius: 1.4, hardness: 0.6, spacing: 0.05, opacity: 0.9) { s in
                s.name = "Pastel sec"
                s.shape = pastelStick
                s.followStroke = true
                s.rotationJitter = 0.3
                setGrain(&s, roughPaper, scale: 2.2, depth: 0.95, blend: .linearBurn)
                s.pressureAffectsOpacity = true
                s.pressureOpacityAmount = 0.6
                s.pressureSizeAmount = 0.3
                s.rendering = .intenseGlaze
                s.flow = 0.7
            }),
            BuiltInBrush(category: "Techniques sèches", name: "Craie grasse", settings: preset(radius: 1.2, hardness: 0.7, spacing: 0.05) { s in
                s.name = "Craie grasse"
                s.shape = pastelStick
                s.followStroke = true
                setGrain(&s, wax, scale: 2, depth: 0.85, blend: .linearBurn)
                s.pressureSizeAmount = 0.4
                s.flow = 0.9
            }),
            BuiltInBrush(category: "Techniques sèches", name: "Sanguine", settings: preset(radius: 0.7, hardness: 0.7, spacing: 0.06, opacity: 0.9) { s in
                s.name = "Sanguine"
                s.shape = charcoal
                s.rotationJitter = .pi
                setGrain(&s, paper, scale: 1.5, depth: 0.9)
                s.pressureAffectsOpacity = true
                s.pressureOpacityAmount = 0.7
                s.rendering = .intenseGlaze
                s.flow = 0.55
                s.tiltSize = 1.5
            }),

            // MARK: Effets
            BuiltInBrush(category: "Effets", name: "Éponge", settings: preset(radius: 3, hardness: 0.8, spacing: 0.35, opacity: 0.85) { s in
                s.name = "Éponge"
                s.shape = sponge
                s.rotationJitter = .pi
                s.randomizeRotation = true
                s.sizeJitter = 0.2
                s.pressureSizeAmount = 0.3
                s.pressureAffectsOpacity = true
                s.pressureOpacityAmount = 0.5
            }),
            BuiltInBrush(category: "Effets", name: "Bruit", settings: preset(radius: 4, hardness: 0.3, spacing: 0.15, opacity: 0.7) { s in
                s.name = "Bruit"
                setGrain(&s, speckle, scale: 1, depth: 1, blend: .linearBurn)
                s.pressureAffectsSize = false
                s.pressureAffectsOpacity = true
                s.pressureOpacityAmount = 0.8
            }),
            BuiltInBrush(category: "Effets", name: "Gribouillis", settings: preset(radius: 0.25, hardness: 0.9, spacing: 0.1) { s in
                s.name = "Gribouillis"
                s.scatter = 1.5
                s.longitudinalJitter = 0.5
                s.stampCount = 3
                s.sizeJitter = 0.5
                s.opacityJitter = 0.4
            }),
            BuiltInBrush(category: "Effets", name: "Lueur", settings: preset(radius: 3, hardness: 0, spacing: 0.08, opacity: 0.35) { s in
                s.name = "Lueur"
                s.pressureAffectsSize = false
                s.pressureAffectsOpacity = true
                s.pressureOpacityAmount = 1
                s.rendering = .intenseGlaze
                s.flow = 0.2
            }),
        ]
    }
}
