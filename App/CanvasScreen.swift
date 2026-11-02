import MetalKit
import PRCore
import PREngine
import PRImaging
import PRStorage
import simd
import SwiftUI
import UIKit

enum PaintTool: String, CaseIterable {
    case brush
    case eraser
    case smudge
    case clone
    case fill
    case gradient
    case select
    case liquify
    case effect

    var label: String {
        switch self {
        case .brush: "Pinceau"
        case .eraser: "Gomme"
        case .smudge: "Doigt"
        case .clone: "Clonage"
        case .fill: "Remplissage"
        case .gradient: "Dégradé"
        case .select: "Sélection"
        case .liquify: "Liquify"
        case .effect: "Pinceau d'effet"
        }
    }

    var symbol: String {
        switch self {
        case .brush: "paintbrush.pointed"
        case .eraser: "eraser"
        case .smudge: "hand.point.up.left"
        case .clone: "square.on.square.dashed"
        case .fill: "drop"
        case .gradient: "circle.lefthalf.striped.horizontal"
        case .select: "lasso"
        case .liquify: "tornado"
        case .effect: "wand.and.rays"
        }
    }

    /// Outils qui lisent les pixels pendant le trait : chemin CPU.
    var needsCPU: Bool { self == .smudge || self == .clone || self == .liquify || self == .effect }
}

/// État de l'écran Toile : un calque, l'historique, la vue, les outils et l'affichage.
@MainActor
@Observable
final class CanvasSession {
    static let canvasWidth = 8192
    static let morphDuration = 0.6
    static let maxRecentColors = 10

    /// La pile est une classe : `layersVersion` signale ses changements à SwiftUI.
    @ObservationIgnored private(set) var stack = LayerStack(width: CanvasSession.canvasWidth, height: CanvasSession.canvasWidth / 2)
    private(set) var history = UndoRedoManager()
    var layersVersion = 0
    var activeID = UUID()
    private(set) var paintingMask = false
    /// Calques garantis par la mémoire disponible au dernier contrôle (voir `MemoryBudget`).
    private(set) var guaranteedLayers = LayerStack.maxLayers
    var showLayers = false
    // Interface façon Procreate (voir TopBar.swift)
    var showingGallery = true
    /// Réglage de taille en cours : un cercle montre la taille du pinceau sur la toile.
    var showSizePreview = false
    var showActions = false
    var showAdjustments = false
    var showBrushes = false
    var exportKind: ExportKind = .exr
    var toast: String?
    /// Gestes de navigation en cours : la grille s'affiche pour qu'on voie la sphère tourner.
    var isNavigating = false
    /// Change à chaque opération (vignettes des calques).
    var historyRevision = 0
    @ObservationIgnored var toastTask: Task<Void, Never>?
    @ObservationIgnored var structureBeforeEdit: [StackItem]?

    /// Créé par le coordinateur Metal (il faut le GPU).
    @ObservationIgnored var canvas: StackCanvas?
    @ObservationIgnored var device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()

    // Fichier (voir ProjectFiles.swift)
    var projectName = "Sans titre"
    var projectCreatedAt = Date()
    /// Fichier du projet (nil tant qu'il n'a jamais été enregistré).
    var projectURL: URL?
    var hasUnsavedChanges = false
    @ObservationIgnored var autosaveTask: Task<Void, Never>?
    /// Dernière capture de la vue dépliée (vignette de la galerie).
    /// Rendu hors écran (vignette de la galerie, timelapse), fourni par la vue Metal.
    @ObservationIgnored var renderer: PanoramaRenderer?
    var showProjects = false
    var showSnapshots = false
    var showExport = false
    var fileMessage: String?
    var isExporting = false
    var exportProgress = 0.0
    var lastExportURLs: [URL] = []
    @ObservationIgnored var exportCancel: CancelFlag?
    /// Lu à chaque image et modifié par les gestes : hors observation pour ne pas redessiner SwiftUI en continu.
    @ObservationIgnored var view = ViewState()

    private(set) var mode: ViewMode = .sphere
    private(set) var horizonLocked = false
    private(set) var fovDegrees = 90.0
    private(set) var canUndo = false
    private(set) var canRedo = false
    var recentColors: [SIMD3<Double>] = []
    private(set) var blendSpace: BlendSpace = .perceptual
    var tool: PaintTool = .brush
    var brush = BrushSettings.defaultBrush
    var eraser = BrushSettings.defaultEraser
    /// Couleur courante, composantes encodées sRGB dans [0, 1].
    var color: SIMD3<Double> = [0.15, 0.35, 0.85]
    /// Couleur secondaire (dynamique de couleur), en sRGB encodé comme `color`.
    var secondaryColor: SIMD3<Double> = [0.95, 0.85, 0.3]
    var toneMapping: ToneMapping = .clip
    var exposure = 0.0
    var showColorPicker = false

    // Outils sphériques (voir SphereToolsUI.swift)
    var symmetry = SymmetrySettings()
    var guidesEnabled = false
    var guideSpacing = 15.0
    var gradientShape: SphericalGradient.Shape = .linear
    var fillThreshold = 0.1
    var smudgeStrength = 0.6
    var cloneSource: Vec3?
    var showRotation = false
    /// Aperçu de rotation de la sphère, en degrés (lacet, tangage, roulis).
    var sphereRotation: SIMD3<Double> = .zero
    @ObservationIgnored var warp: WarpEngine?
    @ObservationIgnored var cloneSampler: LayerSampler?
    @ObservationIgnored var cloneRotation = matrix_identity_double3x3
    @ObservationIgnored var gradientStart: Vec3?
    @ObservationIgnored var lastDirection: Vec3?
    @ObservationIgnored var smudgePrevious: [Vec3] = []
    @ObservationIgnored var lastAspect = 1.5

    // Sélection et transformation (voir SelectionUI.swift)
    @ObservationIgnored var selection: SelectionMask?
    var hasSelection = false
    var selectionKind: SelectionKind = .rectangle
    var selectionCombine: SelectionCombine = .replace
    var selectionThreshold = 0.1
    /// Tracé en cours, en NDC (affiché par-dessus la toile).
    var selectionDrag: [SIMD2<Double>] = []
    var transform: SphericalTransform?

    // Lot C (voir DeformationUI.swift)
    var liquifyMode: LiquifyMode = .push
    var liquifyStrength = 0.6
    var quickShapeEnabled = true
    var distort: SphericalDistort?
    var showTextSheet = false

    // Phase 6 (voir AdjustmentsUI.swift)
    var activeFilter: FilterKind?
    var filterSettings = FilterSettings()
    var filterPreviewIsLive = false

    // Phase 7 (voir ImportUI.swift, BrushLibraryUI.swift)
    var pendingImport: PendingImport?
    var showImporter = false
    var isDecodingImport = false
    var showBrushLibrary = false
    var showBrushStudio = false
    /// Points de réinitialisation des pinceaux (Atelier > À propos), par nom.
    var brushResetPoints: [String: BrushResetPoint] = [:]
    var showTimelapse = false
    var interfaceHidden = false
    var showPreferences = false
    var preferences = Preferences.decode(UserDefaults.standard.data(forKey: "preferences")) {
        didSet { UserDefaults.standard.set(preferences.encoded(), forKey: "preferences") }
    }
    /// Désactivé par défaut : une capture après chaque opération coûte du temps.
    var timelapseEnabled = false
    var timelapseFrames = 0
    @ObservationIgnored var timelapse: TimelapseRecorder?
    @ObservationIgnored var timelapseCaptureRequested = false
    @ObservationIgnored var previousDabCenter: Vec3?
    @ObservationIgnored var strokeRandom = StrokeRandom(seed: 1)
    /// Stabilisation du trait en cours (nil si le pinceau n'en a pas).
    @ObservationIgnored var stabilizer: StrokeStabilizer?
    // Contexte du trait en cours (effilement, vitesse, inclinaison, tirages du grain et de la forme).
    @ObservationIgnored var strokeDistance = 0.0
    @ObservationIgnored var strokeSpeed = 0.0
    @ObservationIgnored var strokeTilt = 0.0
    @ObservationIgnored var lastMoveTime: CFTimeInterval = 0
    @ObservationIgnored var strokeGrainOffset = SIMD2<Double>.zero
    @ObservationIgnored var strokeRotationOffset = 0.0
    /// Dernier azimut connu du Pencil (dans le plan tangent), tirages de couleur du trait.
    @ObservationIgnored var strokeAzimuth: Double?
    @ObservationIgnored var strokeColorDraw = ColorDraw.none
    /// Mélange humide : une réserve par copie de symétrie, et la toile d'avant le trait d'où elles prennent la couleur.
    @ObservationIgnored private var wetMixers: [WetMixer] = []
    @ObservationIgnored private var wetSampler: LayerSampler?
    @ObservationIgnored var activeCorner: Int?
    @ObservationIgnored var quickShapePoints: [Vec3] = []
    @ObservationIgnored var quickShapePressure = 1.0
    @ObservationIgnored var quickShapeLastMove: CFTimeInterval = 0
    @ObservationIgnored var quickShapeTimer: Timer?
    @ObservationIgnored var quickShapeApplied = false

    @ObservationIgnored private var sampler = SphericalStrokeSampler()
    /// Pinceau double : le secondaire a son propre espacement, ses propres tirages.
    @ObservationIgnored private var secondaryRandom = StrokeRandom(seed: 2)
    /// Pinceau et gomme : dabs posés le long d'une courbe lisse (pression et inclinaison interpolées dab par dab).
    @ObservationIgnored private var brushPath = SplineStrokeSampler()
    @ObservationIgnored private var secondaryPath = SplineStrokeSampler()
    /// Dabs du trait à masque avec leur distance au départ : l'effilement de fin les reprend au lever.
    @ObservationIgnored private var strokeRecords: [(dab: SphericalDab, distance: Double)] = []
    @ObservationIgnored var previousSecondaryCenter: Vec3?
    @ObservationIgnored private var morphAnimation: (from: Double, to: Double, start: CFTimeInterval)?
    @ObservationIgnored private var rollAnimation: (from: Double, to: Double, start: CFTimeInterval)?

    var settings: BrushSettings {
        get { tool == .brush ? brush : eraser }
        set { if tool == .brush { brush = newValue } else { eraser = newValue } }
    }

    // MARK: - Vues

    func setMode(_ newMode: ViewMode) {
        switch newMode {
        case .unfolded:
            guard mode != .unfolded else { return }
            if mode == .flat { view.morph = 0 }
            view.prepareUnfold()
            view.mode = .unfolded
            animateMorph(to: 1)
        case .sphere:
            if mode == .unfolded {
                view.prepareFold()
                view.mode = .sphere
                animateMorph(to: 0)
            } else {
                view.mode = .sphere
                view.morph = 0
            }
        case .flat:
            morphAnimation = nil
            view.morph = 0
            view.showFace(view.face)
        }
        mode = newMode
        refreshViewInfo()
    }

    func toggleUnfold() {
        setMode(mode == .unfolded ? .sphere : .unfolded)
    }

    func showFace(_ face: CubeFace) {
        morphAnimation = nil
        view.morph = 0
        view.showFace(face)
        mode = .flat
        refreshViewInfo()
    }

    func setHorizonLocked(_ locked: Bool) {
        view.horizonLocked = locked
        if locked { view.roll = 0 }
        horizonLocked = locked
    }

    func setBlendSpace(_ space: BlendSpace) {
        blendSpace = space
        canvas?.blendSpace = space
    }

    /// Avance les animations de dépliage et de roulis (appelé à chaque image).
    func advance(now: CFTimeInterval) {
        if let anim = rollAnimation {
            let t = min(1, (now - anim.start) / 0.2)
            let eased = t * t * (3 - 2 * t)
            view.roll = anim.from + (anim.to - anim.from) * eased
            if t >= 1 { rollAnimation = nil }
        }
        guard let anim = morphAnimation else { return }
        let t = min(1, (now - anim.start) / Self.morphDuration)
        let eased = t * t * (3 - 2 * t)
        view.morph = anim.from + (anim.to - anim.from) * eased
        if t >= 1 { morphAnimation = nil }
    }

    /// Le geste de rotation commence : une animation de calage en cours s'arrête là.
    func rotationBegan() {
        rollAnimation = nil
    }

    /// Fin du geste de rotation : près d'un angle droit, la vue s'y cale (aimant).
    func rotationEnded() {
        guard let target = ViewState.snappedRoll(view.roll) else { return }
        rollAnimation = (view.roll, target, CACurrentMediaTime())
    }

    /// Remet l'horizon droit (menu de la vue), par le plus court chemin.
    func straightenView() {
        let turn = 2 * Double.pi
        let target = (view.roll / turn).rounded() * turn
        rollAnimation = (view.roll, target, CACurrentMediaTime())
    }

    private func animateMorph(to target: Double) {
        morphAnimation = (view.morph, target, CACurrentMediaTime())
    }

    func refreshViewInfo() {
        fovDegrees = (mode == .flat ? view.flatFov : view.fov) * 180 / .pi
    }

    // MARK: - Peinture

    /// Couleur courante en RGB linéaire.
    var linearColor: SIMD3<Float> {
        ColorTransfer.toLinear(SIMD3<Float>(Float(color.x), Float(color.y), Float(color.z)))
    }

    func dab(at center: Vec3, pressure: Double, strokeAngle: Double = 0, random: DabRandom = .none,
             context: StrokeContext = .none) -> SphericalDab {
        settings.dab(at: center, pressure: pressure, color: linearColor, mode: tool == .brush ? .paint : .erase,
                            strokeAngle: strokeAngle, random: random, context: context)
    }

    /// `azimuth` : point d'écran (NDC) un peu plus loin dans la direction de l'azimut du Pencil (nil au doigt).
    func strokeBegan(ndc: SIMD2<Double>, aspect: Double, pressure: Double, tilt: Double = 0, azimuth: SIMD2<Double>? = nil) {
        strokeTilt = tilt
        strokeAzimuth = view.direction(atNDC: ndc, aspect: aspect).flatMap { azimuthAngle(at: $0, toward: azimuth, aspect: aspect) }
        let mapped = preferences.mappedPressure(pressure)
        // Stabilisation (Atelier) : un stabilisateur neuf par trait, pour les outils qui peignent.
        stabilizer = stabilizesStroke && settings.stabilizer.isActive ? StrokeStabilizer(settings: settings.stabilizer) : nil
        let (ndc, pressure) = stabilize(ndc, mapped)
        lastAspect = aspect
        guard let canvas, let d = view.direction(atNDC: ndc, aspect: aspect) else { return }
        lastDirection = d
        if distort != nil {
            grabDistortCorner(ndc: ndc)
            return
        }
        if transform != nil {
            moveTransform(to: d)
            return
        }
        if tool == .select {
            selectionBegan(ndc: ndc, direction: d)
            return
        }
        switch tool {
        case .fill:
            fill(at: d)
            return
        case .gradient:
            gradientStart = d
            return
        case .clone where cloneSource == nil:
            cloneSource = d
            fileMessage = "Source du clonage définie : peins ailleurs pour la recopier"
            return
        default:
            break
        }
        canvas.forceCPU = tool.needsCPU
        // Pinceau et gomme : trait à masque (glacis, flux, pinceau double).
        let masked = tool == .brush || tool == .eraser
        canvas.beginStroke(style: masked ? settings.strokeStyle(color: linearColor, mode: tool == .brush ? .paint : .erase) : nil)
        if tool == .brush { rememberColor() }
        previousDabCenter = nil
        strokeRandom = StrokeRandom(seed: UInt64.random(in: 1...UInt64.max))
        strokeDistance = 0
        strokeSpeed = 0
        lastMoveTime = CACurrentMediaTime()
        strokeGrainOffset = [strokeRandom.next(), strokeRandom.next()]
        strokeRotationOffset = strokeRandom.next() * 2 * .pi
        secondaryRandom = StrokeRandom(seed: UInt64.random(in: 1...UInt64.max))
        previousSecondaryCenter = nil
        strokeRecords = []
        strokeColorDraw = strokeRandom.colorDraw()
        wetMixers = []
        wetSampler = tool == .brush && settings.wetMixActive ? canvas.stack.item(canvas.activeID)?.layer.map { LayerSampler($0) } : nil
        let first = StrokeSample(point: d, pressure: pressure, tilt: tilt, azimuth: strokeAzimuth)
        let firstDabs = brushPath.begin(first)
        let firstSecondary = secondaryPath.begin(first)
        let centers = sampler.begin(at: d)
        switch tool {
        case .smudge, .liquify:
            smudgePrevious = symmetry.images(of: d)
        case .effect:
            applyClone(centers, pressure: pressure)
        case .clone:
            beginClone(at: d)
            applyClone(centers, pressure: pressure)
        default:
            canvas.add(symmetricDabs(firstDabs) + secondaryDabs(settings.resolvedSecondary == nil ? [] : firstSecondary))
            beginQuickShapeWatch(at: d, pressure: pressure)
        }
    }

    func strokeMoved(ndc: SIMD2<Double>, aspect: Double, pressure: Double, tilt: Double = 0, azimuth: SIMD2<Double>? = nil,
                     alreadyMapped: Bool = false) {
        strokeTilt = tilt
        if azimuth != nil, let raw = view.direction(atNDC: ndc, aspect: aspect) {
            strokeAzimuth = azimuthAngle(at: raw, toward: azimuth, aspect: aspect) ?? strokeAzimuth
        }
        let mapped = alreadyMapped ? pressure : preferences.mappedPressure(pressure)
        let (ndc, pressure) = alreadyMapped ? (ndc, mapped) : stabilize(ndc, mapped)
        lastAspect = aspect
        if tool == .select, transform == nil {
            selectionMoved(ndc: ndc)
            return
        }
        guard let d = view.direction(atNDC: ndc, aspect: aspect) else { return }
        // Vitesse du trait (Dynamique > Vitesse), lissée ; les touches regroupées d'une même image ne comptent pas.
        let now = CACurrentMediaTime()
        if let last = lastDirection, now - lastMoveTime > 0.004 {
            let instant = Sphere.angle(last, d) / (now - lastMoveTime)
            strokeSpeed = strokeSpeed * 0.7 + instant * 0.3
            lastMoveTime = now
        }
        lastDirection = d
        if distort != nil {
            moveDistortCorner(to: d)
            return
        }
        if transform != nil {
            moveTransform(to: d)
            return
        }
        guard let canvas, canvas.isStroking, !quickShapeApplied else { return }
        switch tool {
        case .smudge, .liquify, .clone, .effect:
            let spacing = settings.spacing(radius: settings.radius(pressure: pressure), random: strokeRandom.next(), speed: strokeSpeed)
            let centers = sampler.add(d, spacing: spacing)
            switch tool {
            case .smudge: applySmudge(centers, pressure: pressure)
            case .liquify: applyLiquify(centers, pressure: pressure)
            default: applyClone(centers, pressure: pressure)
            }
        default:
            canvas.add(advancePaths(StrokeSample(point: d, pressure: pressure, tilt: tilt, azimuth: strokeAzimuth), finishing: false))
            noteQuickShapePoint(d)
        }
    }

    /// Fait avancer les courbes du pinceau (et de son secondaire) jusqu'à `sample`, ou les termine au lever ;
    /// renvoie les dabs des segments complétés.
    private func advancePaths(_ sample: StrokeSample?, finishing: Bool) -> [SphericalDab] {
        let brush = settings
        var path = brushPath
        let primarySpacing: (Double) -> Double = { p in
            brush.spacing(radius: brush.radius(pressure: p), random: self.strokeRandom.next(), speed: self.strokeSpeed)
        }
        let samples = sample.map { path.add($0, spacing: primarySpacing) } ?? (finishing ? path.finish(spacing: primarySpacing) : [])
        brushPath = path
        var dabs = symmetricDabs(samples)
        if let secondary = brush.resolvedSecondary {
            var second = secondaryPath
            let secondarySpacing: (Double) -> Double = { p in
                secondary.spacing(radius: secondary.radius(pressure: p), random: self.secondaryRandom.next(), speed: self.strokeSpeed)
            }
            let secondSamples = sample.map { second.add($0, spacing: secondarySpacing) }
                ?? (finishing ? second.finish(spacing: secondarySpacing) : [])
            secondaryPath = second
            dabs += secondaryDabs(secondSamples)
        }
        return dabs
    }

    /// Dabs du trait et leurs copies par symétrie.
    /// Chaque copie garde l'angle de son propre trait (les reflets tournent dans l'autre sens).
    func symmetricDabs(_ centers: [Vec3], pressure: Double) -> [SphericalDab] {
        symmetricDabs(centers.map { StrokeSample(point: $0, pressure: pressure, tilt: strokeTilt) })
    }

    /// Dabs aux points du trait (pression et inclinaison propres à chacun) et leurs copies par symétrie.
    func symmetricDabs(_ samples: [StrokeSample]) -> [SphericalDab] {
        var dabs: [SphericalDab] = []
        for sample in samples {
            let center = sample.point
            if let previous = previousDabCenter { strokeDistance += Sphere.angle(previous, center) }
            let images = symmetry.images(of: center)
            let previous = symmetry.images(of: previousDabCenter ?? center)
            var context = strokeContext(tilt: sample.tilt)
            let azimuths = symmetricAzimuths(sample, images: images)
            // Plusieurs tampons par dab (Forme > Nombre) ; mêmes tirages pour toutes les copies de symétrie.
            let count = settings.stampCount(random: strokeRandom.next())
            for _ in 0..<count {
                let random = settings.hasJitter ? strokeRandom.dab() : .none
                for (i, image) in images.enumerated() {
                    let angle = i < previous.count ? BrushSettings.strokeAngle(from: previous[i], to: image) : 0
                    context.azimuth = azimuths[i]
                    var made = dab(at: image, pressure: sample.pressure, strokeAngle: angle, random: random, context: context)
                    if wetSampler != nil { wetMix(&made, image: i, random: random) }
                    strokeRecords.append((made, strokeDistance))
                    dabs.append(made)
                }
            }
            previousDabCenter = center
        }
        return dabs
    }

    func secondaryDabs(_ centers: [Vec3], pressure: Double) -> [SphericalDab] {
        secondaryDabs(centers.map { StrokeSample(point: $0, pressure: pressure, tilt: strokeTilt) })
    }

    /// Dabs du pinceau secondaire d'un pinceau double (vide sinon), avec leurs copies par symétrie.
    func secondaryDabs(_ samples: [StrokeSample]) -> [SphericalDab] {
        guard let secondary = settings.resolvedSecondary, !samples.isEmpty else { return [] }
        var dabs: [SphericalDab] = []
        let mode: DabMode = tool == .brush ? .paint : .erase
        for sample in samples {
            let center = sample.point
            let images = symmetry.images(of: center)
            let previous = symmetry.images(of: previousSecondaryCenter ?? center)
            var context = strokeContext(tilt: sample.tilt)
            let azimuths = symmetricAzimuths(sample, images: images)
            let count = secondary.stampCount(random: secondaryRandom.next())
            for _ in 0..<count {
                let random = secondary.hasJitter ? secondaryRandom.dab() : .none
                for (i, image) in images.enumerated() {
                    let angle = i < previous.count ? BrushSettings.strokeAngle(from: previous[i], to: image) : 0
                    context.azimuth = azimuths[i]
                    var dab = secondary.dab(at: image, pressure: sample.pressure, color: linearColor, mode: mode, strokeAngle: angle,
                                            random: random, context: context)
                    dab.secondary = true
                    strokeRecords.append((dab, strokeDistance))
                    dabs.append(dab)
                }
            }
            previousSecondaryCenter = center
        }
        return dabs
    }

    /// Contexte d'un dab du trait en cours (l'azimut est propre à chaque copie de symétrie).
    private func strokeContext(tilt: Double) -> StrokeContext {
        StrokeContext(distance: strokeDistance, speed: strokeSpeed, tilt: tilt, grainOffset: strokeGrainOffset,
                      rotationOffset: strokeRotationOffset, colorDraw: strokeColorDraw,
                      secondaryColor: ColorTransfer.toLinear(SIMD3<Float>(secondaryColor)))
    }

    /// Azimut du Pencil pour chaque copie de symétrie : un point voisin dans la direction de l'azimut est reflété avec
    /// le point du trait, et l'angle est relu dans le plan tangent de chaque copie (les reflets tournent dans l'autre sens).
    private func symmetricAzimuths(_ sample: StrokeSample, images: [Vec3]) -> [Double?] {
        guard let azimuth = sample.azimuth else { return images.map { _ in nil } }
        guard images.count > 1 else { return [azimuth] }
        let ahead = TangentFrame(center: sample.point).unproject([cos(azimuth) * 1e-3, sin(azimuth) * 1e-3])
        let aheadImages = symmetry.images(of: ahead)
        return images.indices.map { i in
            guard i < aheadImages.count else { return azimuth }
            return BrushSettings.strokeAngle(from: aheadImages[i], to: images[i]) + .pi
        }
    }

    /// Azimut du Pencil au point `d` du trait : direction de `d` vers le point d'écran `toward` (en NDC), dans le plan tangent.
    private func azimuthAngle(at d: Vec3, toward ndc: SIMD2<Double>?, aspect: Double) -> Double? {
        guard let ndc, let ahead = view.direction(atNDC: ndc, aspect: aspect), Sphere.angle(d, ahead) > 1e-9 else { return nil }
        return BrushSettings.strokeAngle(from: ahead, to: d) + .pi
    }

    /// Mélange humide d'un tampon du principal : la réserve de la copie `image` prend la couleur de la toile sous le tampon.
    private func wetMix(_ dab: inout SphericalDab, image: Int, random: DabRandom) {
        while wetMixers.count <= image { wetMixers.append(WetMixer()) }
        let pickup = canvasColor(around: dab.center, radius: dab.radius * 0.6)
        let wide = settings.wetBlur > 0 ? canvasColor(around: dab.center, radius: dab.radius * 2) : pickup
        wetMixers[image].apply(&dab, brush: settings, distance: strokeDistance, pickup: pickup, wide: wide, random: random)
    }

    /// Couleur moyenne de la toile (calque actif d'avant le trait) autour de `center` : le centre et six points sur un cercle.
    private func canvasColor(around center: Vec3, radius: Double) -> SIMD4<Float> {
        guard let sampler = wetSampler else { return .zero }
        let frame = TangentFrame(center: center)
        var sum = sampler.sample(direction: center)
        for k in 0..<6 {
            let a = Double(k) * .pi / 3
            sum += sampler.sample(direction: frame.unproject([cos(a) * radius, sin(a) * radius]))
        }
        return sum / 7
    }

    /// Anticipation : les touches prédites du Pencil (où la main sera dans quelques millisecondes) sont tracées à l'avance
    /// et montrées une image ; le trait réel les remplace dès qu'il arrive. Sans effet sur l'état du trait.
    func strokePredicted(_ points: [(ndc: SIMD2<Double>, pressure: Double, tilt: Double, azimuth: SIMD2<Double>?)], aspect: Double) {
        guard let canvas, canvas.isStroking else { return }
        guard canvas.usesFastPath, tool == .brush || tool == .eraser, stabilizer == nil, !quickShapeApplied,
              transform == nil, distort == nil, !points.isEmpty else {
            canvas.setPrediction([])
            return
        }
        let saved = (brushPath, secondaryPath, strokeRandom, secondaryRandom, previousDabCenter, previousSecondaryCenter,
                     strokeDistance, strokeRecords.count, wetMixers)
        var dabs: [SphericalDab] = []
        for point in points {
            guard let d = view.direction(atNDC: point.ndc, aspect: aspect) else { continue }
            let sample = StrokeSample(point: d, pressure: preferences.mappedPressure(point.pressure), tilt: point.tilt,
                                      azimuth: azimuthAngle(at: d, toward: point.azimuth, aspect: aspect) ?? strokeAzimuth)
            dabs += advancePaths(sample, finishing: false)
        }
        dabs += advancePaths(nil, finishing: true)
        (brushPath, secondaryPath, strokeRandom, secondaryRandom, previousDabCenter, previousSecondaryCenter,
         strokeDistance, _, wetMixers) = saved
        strokeRecords.removeLast(strokeRecords.count - saved.7)
        canvas.setPrediction(dabs)
    }

    /// Effilement de fin : au lever, le trait est repeint avec ses derniers dabs affinés (taille et opacité).
    private func applyEndTaper(_ canvas: StackCanvas) {
        let brush = settings
        let secondary = brush.resolvedSecondary
        guard brush.taperEndLength > 0 || (secondary?.taperEndLength ?? 0) > 0, !strokeRecords.isEmpty else { return }
        let total = strokeDistance
        var changed = false
        let dabs = strokeRecords.map { record -> SphericalDab in
            var dab = record.dab
            let taper = (dab.secondary ? secondary ?? brush : brush).endTaper(remaining: total - record.distance)
            if taper.size < 1 || taper.opacity < 1 {
                changed = true
                dab.radius = max(1e-5, dab.radius * taper.size)
                dab.color.w *= Float(taper.opacity)
            }
            return dab
        }
        if changed { canvas.replaceStroke(with: dabs) }
    }

    func strokeEnded() {
        // StreamLine : le trait rattrape la dernière position de la main avant de se terminer.
        if var pending = stabilizer {
            stabilizer = nil
            for point in pending.finish(step: 0.004) {
                strokeMoved(ndc: point.point, aspect: lastAspect, pressure: point.pressure, tilt: strokeTilt, alreadyMapped: true)
            }
        }
        stopQuickShapeWatch()
        if distort != nil {
            activeCorner = nil
            return
        }
        if transform != nil { return }
        if tool == .select {
            selectionEnded()
            return
        }
        if tool == .gradient, let start = gradientStart, let end = lastDirection {
            gradientStart = nil
            applyGradient(from: start, to: end)
            return
        }
        guard let canvas, canvas.isStroking else { return }
        // Pinceau et gomme : dernier segment de la courbe, puis effilement de fin (sauf forme rapide déjà posée).
        if tool == .brush || tool == .eraser, !quickShapeApplied {
            canvas.add(advancePaths(nil, finishing: true))
            applyEndTaper(canvas)
        }
        if let result = canvas.endStroke(), !result.deltas.isEmpty {
            history.record(HistoryEntry(name: tool == .brush ? "Trait" : "Gomme", layerID: result.layerID, deltas: result.deltas))
        }
        wetSampler = nil
        refreshHistory()
    }

    /// Second doigt posé ou pipette : le trait commencé disparaît sans laisser de trace.
    func strokeCancelled() {
        stabilizer = nil
        wetSampler = nil
        canvas?.cancelStroke()
    }

    /// Outils dont le trait est stabilisé (pas la sélection, ni les poignées de transformation).
    private var stabilizesStroke: Bool {
        transform == nil && distort == nil && [PaintTool.brush, .eraser, .smudge, .clone, .effect, .liquify].contains(tool)
    }

    /// Point et pression stabilisés (inchangés sans stabilisateur).
    private func stabilize(_ ndc: SIMD2<Double>, _ pressure: Double) -> (SIMD2<Double>, Double) {
        guard stabilizer != nil else { return (ndc, pressure) }
        let result = stabilizer!.add(ndc, pressure: pressure)
        return (result.point, result.pressure)
    }

    // MARK: - Historique

    func undo() {
        strokeCancelled()
        cancelTransform()
        cancelDistort()
        if let entry = try? history.undo(in: historyTarget) {
            invalidate(entry)
            showToast("Annuler : \(entry.name)")
        } else {
            showToast("Rien à annuler")
        }
        refreshHistory()
    }

    func redo() {
        strokeCancelled()
        cancelTransform()
        cancelDistort()
        if let entry = try? history.redo(in: historyTarget) {
            invalidate(entry)
            showToast("Rétablir : \(entry.name)")
        } else {
            showToast("Rien à rétablir")
        }
        refreshHistory()
    }

    /// La pile et la sélection : tout ce que l'historique peut restaurer.
    private var historyTarget: HistoryTarget { SessionHistoryTarget(stack: stack, selection: selection) }

    private func invalidate(_ entry: HistoryEntry) {
        let changes = entry.allChanges
        if let selection, changes.contains(where: { $0.layerID == selection.layer.id }) { selectionUpdated() }
        if entry.structure != nil || entry.isSpilled || changes.count > 1 {
            structureChanged()
        } else if entry.layerID != selection?.layer.id {
            canvas?.invalidate(entry.deltas.map(\.coord), layerID: entry.layerID)
        }
    }

    /// Remplace la pile (nouveau projet, ouverture) : caches GPU reconstruits, historique vidé.
    func replaceStack(_ newStack: LayerStack) {
        strokeCancelled()
        stack = newStack
        history = UndoRedoManager(maxSteps: preferences.historyLimit)
        // Les textures d'affichage ont la taille de la toile : une autre résolution (projet 4K après un 8K,
        // résolution réduite) demande une toile neuve, sinon le calque n'occupe qu'une partie de la texture.
        if let canvas, canvas.stack.width == newStack.width, canvas.stack.height == newStack.height {
            canvas.replaceStack(newStack)
        } else {
            canvas = StackCanvas(stack: newStack, device: device)
        }
        canvas?.blendSpace = blendSpace
        // La sélection appartient à l'ancienne toile (et peut avoir une autre taille).
        selection = nil
        canvas?.selection = nil
        hasSelection = false
        activeID = canvas?.activeID ?? newStack.items.last { !$0.isGroup }!.id
        paintingMask = false
        refreshHistory()
        structureChanged()
        // Un projet qu'on vient d'ouvrir ou de créer n'a rien à enregistrer.
        autosaveTask?.cancel()
        hasUnsavedChanges = false
    }

    /// Après tout changement de structure ou de propriété : calque actif valide, caches à refaire, interface à jour.
    func structureChanged() {
        if stack.item(activeID) == nil {
            activeID = stack.items.last { !$0.isGroup }?.id ?? stack.items.last!.id
        }
        if stack.item(activeID)?.mask == nil { paintingMask = false }
        canvas?.activeID = activeID
        canvas?.paintingMask = paintingMask
        canvas?.setNeedsRefresh()
        if let available = MemoryBudgetManager.systemAvailableBytes() {
            guaranteedLayers = stack.guaranteedLayers(availableBytes: available)
        }
        layersVersion += 1
    }

    func selectLayer(_ id: UUID) {
        strokeCancelled()
        activeID = id
        paintingMask = false
        structureChanged()
    }

    func setPaintingMask(_ value: Bool) {
        strokeCancelled()
        paintingMask = value && stack.item(activeID)?.mask != nil
        structureChanged()
    }

    func refreshHistory() {
        canUndo = history.canUndo
        canRedo = history.canRedo
        // Timelapse activé : une image par opération (et par annulation), capturée à la prochaine image affichée.
        timelapseCaptureRequested = timelapseEnabled
        historyRevision += 1
        scheduleAutosave()
    }

    // MARK: - Couleur

    /// Pipette : couleur affichée sous le doigt (toute la pile composée sur le papier blanc).
    func pickColor(ndc: SIMD2<Double>, aspect: Double) {
        guard let d = view.direction(atNDC: ndc, aspect: aspect) else { return }
        let p = Equirect.pixel(from: d, width: stack.width, height: stack.height)
        let x = min(stack.width - 1, max(0, Int(p.x)))
        let y = min(stack.height - 1, max(0, Int(p.y)))
        let coord = TileCoord.containing(x: x, y: y)
        let tile = LayerCompositor.compositeTile(coord, stack: stack, paper: [1, 1, 1], space: blendSpace)
        let px = tile[(y % TileSize.side) * TileSize.side + x % TileSize.side]
        let encoded = ColorTransfer.toEncoded(SIMD3<Float>(px.x, px.y, px.z))
        color = [Double(min(1, max(0, encoded.x))), Double(min(1, max(0, encoded.y))), Double(min(1, max(0, encoded.z)))]
        tool = .brush
    }

    func rememberColor() {
        recentColors.removeAll { simd_length($0 - color) < 1e-4 }
        recentColors.insert(color, at: 0)
        if recentColors.count > Self.maxRecentColors { recentColors.removeLast() }
    }
}

// MARK: - Vue Metal

/// Reçoit les touches : un doigt ou le Pencil peint ; un second doigt annule le trait commencé.
final class CanvasMTKView: MTKView {
    weak var coordinator: CanvasCoordinator?

    private var aspect: Double { Double(bounds.width / max(bounds.height, 1)) }

    func ndc(_ p: CGPoint) -> SIMD2<Double> {
        [Double(p.x / bounds.width) * 2 - 1, 1 - Double(p.y / bounds.height) * 2]
    }

    /// Inclinaison du Pencil : 0 = vertical, 1 = à plat ; le doigt n'en a pas (0).
    private func tilt(_ touch: UITouch) -> Double {
        guard touch.type == .pencil else { return 0 }
        return min(1, max(0, 1 - Double(touch.altitudeAngle) / (.pi / 2)))
    }

    /// Position du trait : précise au sous-point pour le Pencil (`location` est arrondie au point d'écran,
    /// ce qui crénelle les traits lents et fins).
    private func point(_ touch: UITouch) -> CGPoint {
        touch.type == .pencil ? touch.preciseLocation(in: self) : touch.location(in: self)
    }

    /// Pression normalisée du Pencil ; le doigt n'en a pas (1).
    private func pressure(_ touch: UITouch) -> Double {
        guard touch.type == .pencil, touch.maximumPossibleForce > 0 else { return 1 }
        return Double(touch.force / touch.maximumPossibleForce)
    }

    /// Touche qui trace le trait en cours (le Pencil ; le doigt seulement si la préférence l'autorise).
    private var drawingTouch: UITouch?

    private var fingerPainting: Bool { coordinator?.session.preferences.fingerPainting ?? false }

    private func canDraw(_ touch: UITouch) -> Bool { touch.type == .pencil || fingerPainting }

    /// Un trait est en cours (la pipette au doigt ne doit pas l'interrompre : main posée sur l'écran).
    var isDrawing: Bool { drawingTouch != nil }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let session = coordinator?.session else { return }
        // Doigts : réservés à la navigation (reconnaisseurs de gestes), sauf en mode « dessiner au doigt ».
        if fingerPainting, (event?.allTouches?.filter { $0.type != .pencil }.count ?? 0) > 1 {
            session.strokeCancelled()
            drawingTouch = nil
            return
        }
        guard drawingTouch == nil, let touch = touches.first(where: canDraw) else { return }
        drawingTouch = touch
        session.strokeBegan(ndc: ndc(point(touch)), aspect: aspect, pressure: pressure(touch), tilt: tilt(touch),
                            azimuth: azimuth(touch))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let session = coordinator?.session, let touch = drawingTouch, touches.contains(touch) else { return }
        if touch.type != .pencil, (event?.allTouches?.filter { $0.type != .pencil }.count ?? 0) > 1 {
            session.strokeCancelled()
            drawingTouch = nil
            return
        }
        for t in event?.coalescedTouches(for: touch) ?? [touch] {
            session.strokeMoved(ndc: ndc(point(t)), aspect: aspect, pressure: pressure(t), tilt: tilt(t), azimuth: azimuth(t))
        }
        // Anticipation : le trait est prolongé jusqu'où UIKit prévoit le Pencil (une image d'avance sur la main).
        let predicted = touch.type == .pencil ? event?.predictedTouches(for: touch) ?? [] : []
        session.strokePredicted(predicted.map { (ndc: ndc(point($0)), pressure: pressure($0), tilt: tilt($0), azimuth: azimuth($0)) },
                                aspect: aspect)
    }

    /// Point d'écran (NDC) à 12 points du Pencil dans la direction de son azimut ; nil au doigt.
    private func azimuth(_ touch: UITouch) -> SIMD2<Double>? {
        guard touch.type == .pencil else { return nil }
        let v = touch.azimuthUnitVector(in: self)
        let p = point(touch)
        return ndc(CGPoint(x: p.x + v.dx * 12, y: p.y + v.dy * 12))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch) else { return }
        drawingTouch = nil
        coordinator?.session.strokeEnded()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch) else { return }
        drawingTouch = nil
        coordinator?.session.strokeCancelled()
    }

    /// Navigation au doigt : un doigt (ou deux) fait tourner la vue quand seul le Pencil dessine.
    weak var panGesture: UIPanGestureRecognizer?

    func applyTouchPreferences() {
        panGesture?.minimumNumberOfTouches = fingerPainting ? 2 : 1
    }
}

@MainActor
final class CanvasCoordinator: NSObject, UIGestureRecognizerDelegate {
    let session: CanvasSession
    let device: (any MTLDevice)?
    private let queue: (any MTLCommandQueue)?
    private let renderer: PanoramaRenderer?
    private var rapidUndoTimer: Timer?

    init(session: CanvasSession) {
        self.session = session
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        queue = device?.makeCommandQueue()
        renderer = device.flatMap { try? PanoramaRenderer(device: $0) }
        session.renderer = renderer
        session.device = device
        if session.canvas == nil { session.replaceStack(session.stack) }
    }

    func render(in view: MTKView) {
        session.advance(now: CACurrentMediaTime())
        guard let renderer, let queue, let canvas = session.canvas,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer() else { return }
        canvas.encodeFrame(into: commands)
        guard let layers = canvas.panoramaLayers() else { return }

        let size = view.drawableSize
        let parameters = session.view.parameters(aspect: Double(size.width / max(size.height, 1)))
        var uniforms = ViewUniforms(parameters, viewportHeight: Int(size.height), textureHeight: layers.below.height,
                                    exposure: session.exposure, toneMapping: session.toneMapping)
        canvas.configure(&uniforms)
        uniforms.setContentRotation(session.showRotation ? session.previewRotation : nil)
        uniforms.setGuides(enabled: session.guidesEnabled || session.isNavigating, spacingDegrees: session.guideSpacing)
        if let distort = session.distort {
            uniforms.setSelection(visible: session.hasSelection, distort: distort)
        } else {
            uniforms.setSelection(visible: session.hasSelection, transform: session.transform)
        }
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        try? renderer.encode(into: encoder, pixelFormat: view.colorPixelFormat, layers: layers, uniforms: uniforms)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
        if session.timelapseCaptureRequested {
            session.timelapseCaptureRequested = false
            commands.waitUntilCompleted() // la capture doit voir les derniers dabs écrits dans les textures
            session.captureTimelapseFrame()
        }
    }

    // MARK: - Navigation

    @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        trackNavigation(gesture)
        session.view.zoom(by: Double(gesture.scale))
        gesture.scale = 1
        session.refreshViewInfo()
    }

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        trackNavigation(gesture)
        guard let view = gesture.view, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let t = gesture.translation(in: view)
        let size = view.bounds.size
        session.view.pan(byNDC: [Double(t.x / size.width) * 2, -Double(t.y / size.height) * 2],
                         aspect: Double(size.width / size.height))
        gesture.setTranslation(.zero, in: view)
    }

    @objc func handleRotation(_ gesture: UIRotationGestureRecognizer) {
        trackNavigation(gesture)
        if gesture.state == .began { session.rotationBegan() }
        session.view.rotate(by: Double(gesture.rotation))
        gesture.rotation = 0
        if gesture.state == .ended || gesture.state == .cancelled { session.rotationEnded() }
    }

    /// Grille visible pendant les gestes de navigation : sur une toile vide, c'est elle qui montre que la vue tourne.
    private func trackNavigation(_ gesture: UIGestureRecognizer) {
        switch gesture.state {
        case .began, .changed: session.isNavigating = true
        default: session.isNavigating = false
        }
    }

    // MARK: - Historique (D6)

    @objc func handleUndoTap(_ gesture: UITapGestureRecognizer) {
        session.perform(session.preferences.twoFingerDoubleTap)
    }

    @objc func handleRedoTap(_ gesture: UITapGestureRecognizer) {
        session.perform(session.preferences.threeFingerDoubleTap)
    }

    @objc func handleFourFingerTap(_ gesture: UITapGestureRecognizer) {
        session.strokeCancelled()
        session.perform(session.preferences.fourFingerTap)
    }

    /// Maintien à deux doigts : annulation rapide continue.
    @objc func handleUndoHold(_ gesture: UILongPressGestureRecognizer) {
        guard session.preferences.rapidUndoHold else { return }
        switch gesture.state {
        case .began:
            session.undo()
            rapidUndoTimer?.invalidate()
            rapidUndoTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.session.undo() }
            }
        case .ended, .cancelled, .failed:
            rapidUndoTimer?.invalidate()
            rapidUndoTimer = nil
        default:
            break
        }
    }

    // MARK: - Pipette

    @objc func handleEyedropper(_ gesture: UILongPressGestureRecognizer) {
        guard session.preferences.eyedropperHold, let view = gesture.view as? CanvasMTKView,
              !view.isDrawing,
              gesture.state == .began || gesture.state == .changed else { return }
        session.strokeCancelled()
        session.pickColor(ndc: view.ndc(gesture.location(in: view)), aspect: Double(view.bounds.width / max(view.bounds.height, 1)))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

extension CanvasCoordinator: @preconcurrency MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        render(in: view)
    }
}

struct MetalCanvas: UIViewRepresentable {
    let session: CanvasSession

    func makeCoordinator() -> CanvasCoordinator {
        CanvasCoordinator(session: session)
    }

    func makeUIView(context: Context) -> CanvasMTKView {
        let coordinator = context.coordinator
        let view = CanvasMTKView(frame: .zero, device: coordinator.device)
        view.coordinator = coordinator
        view.delegate = coordinator
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.preferredFramesPerSecond = 120
        view.isMultipleTouchEnabled = true

        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(CanvasCoordinator.handlePinch(_:)))
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(CanvasCoordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        view.panGesture = pan
        let rotation = UIRotationGestureRecognizer(target: coordinator, action: #selector(CanvasCoordinator.handleRotation(_:)))

        let undoTap = UITapGestureRecognizer(target: coordinator, action: #selector(CanvasCoordinator.handleUndoTap(_:)))
        undoTap.numberOfTouchesRequired = 2
        undoTap.numberOfTapsRequired = 1 // tap simple, comme Procreate : le double tap échouait souvent
        let redoTap = UITapGestureRecognizer(target: coordinator, action: #selector(CanvasCoordinator.handleRedoTap(_:)))
        redoTap.numberOfTouchesRequired = 3
        redoTap.numberOfTapsRequired = 1
        let undoHold = UILongPressGestureRecognizer(target: coordinator, action: #selector(CanvasCoordinator.handleUndoHold(_:)))
        undoHold.numberOfTouchesRequired = 2
        undoHold.minimumPressDuration = 0.6
        let eyedropper = UILongPressGestureRecognizer(target: coordinator, action: #selector(CanvasCoordinator.handleEyedropper(_:)))
        eyedropper.numberOfTouchesRequired = 1
        eyedropper.minimumPressDuration = 0.5

        let fourTap = UITapGestureRecognizer(target: coordinator, action: #selector(CanvasCoordinator.handleFourFingerTap(_:)))
        fourTap.numberOfTouchesRequired = 4
        fourTap.numberOfTapsRequired = 1

        // Double tap sur le Pencil 2 : l'action choisie dans les réglages d'iPadOS.
        let pencil = UIPencilInteraction()
        pencil.delegate = coordinator
        view.addInteraction(pencil)

        for gesture in [pinch, pan, rotation, undoTap, redoTap, undoHold, eyedropper, fourTap] as [UIGestureRecognizer] {
            gesture.delegate = coordinator
            // Gestes au doigt seulement : le Pencil ne fait que dessiner.
            gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            view.addGestureRecognizer(gesture)
        }
        view.applyTouchPreferences()
        return view
    }

    func updateUIView(_ uiView: CanvasMTKView, context: Context) {
        _ = session.preferences.fingerPainting // observé : la préférence s'applique tout de suite
        uiView.applyTouchPreferences()
    }
}

// MARK: - Écran

struct CanvasScreen: View {
    @Bindable var session: CanvasSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .top) {
            MetalCanvas(session: session)
                .ignoresSafeArea()
            SelectionDragOverlay(session: session)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            DistortHandlesOverlay(session: session)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            if !session.interfaceHidden {
                VStack(spacing: 10) {
                    TopBar(session: session)
                    ContextBar(session: session)
                }
                SideRail(session: session)
                    .padding(session.preferences.leftHanded ? .trailing : .leading, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: session.preferences.leftHanded ? .trailing : .leading)
            }
            if session.showSizePreview {
                BrushSizePreview(session: session)
                    .allowsHitTesting(false)
            }
            if let toast = session.toast {
                ToastView(text: toast)
                    .padding(.top, session.interfaceHidden ? 20 : 74)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: session.toast)
        .statusBarHidden(true)
        .dropDestination(for: Data.self) { items, _ in
            guard let data = items.first else { return false }
            session.loadImport(data: data, name: "Glisser-déposer")
            return true
        }
        .sheet(item: $session.pendingImport) { pending in ImportSheet(session: session, pending: pending) }
        .sheet(isPresented: $session.showExport) { ExportSheet(session: session, kind: session.exportKind) }
        .sheet(isPresented: $session.showTimelapse) { TimelapseSheet(session: session) }
        .sheet(isPresented: $session.showPreferences) { PreferencesSheet(session: session) }
        .sheet(isPresented: $session.showSnapshots) { SnapshotsSheet(session: session) }
        .sheet(isPresented: $session.showTextSheet) { TextSheet(session: session) }
        .sheet(isPresented: $session.showBrushLibrary) { BrushLibrarySheet(session: session) }
        .fullScreenCover(isPresented: $session.showBrushStudio) { BrushStudioView(session: session) }
        .sheet(isPresented: $session.showRotation) {
            SphereRotationPanel(session: session)
                .padding(24)
                .presentationDetents([.medium])
        }
        .fileImporter(isPresented: $session.showImporter, allowedContentTypes: importableTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { session.loadImport(urls: urls) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.saveForBackground() }
        }
    }
}

/// Colonne de gauche, comme dans Procreate : taille et opacité de l'outil, annuler / rétablir.
struct SideControls: View {
    @Bindable var session: CanvasSession

    var body: some View {
        VStack(spacing: 28) {
            VerticalSlider(value: $session.settings.radiusDegrees, range: 0.3...30, label: "Taille")
            VerticalSlider(value: $session.settings.opacity, range: 0.02...1, label: "Opacité")
            VStack(spacing: 14) {
                Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!session.canUndo)
                Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!session.canRedo)
            }
            .font(.title3)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            GeometryReader { geo in
                let span = range.upperBound - range.lowerBound
                let fraction = (value - range.lowerBound) / span
                ZStack(alignment: .bottom) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.tint).frame(height: max(10, geo.size.height * fraction))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let f = 1 - min(max(drag.location.y / geo.size.height, 0), 1)
                    value = range.lowerBound + f * span
                })
            }
            .frame(width: 26, height: 170)
        }
    }
}

struct CanvasToolbar: View {
    @Bindable var session: CanvasSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                FileMenu(session: session)
                    .fixedSize()
                LayersButton(session: session)

                Picker("Vue", selection: Binding(get: { session.mode }, set: { session.setMode($0) })) {
                    ForEach(ViewMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)

                Button(session.mode == .unfolded ? "Replier" : "Déplier",
                       systemImage: session.mode == .unfolded ? "globe" : "rectangle.expand.vertical") {
                    session.toggleUnfold()
                }
                .buttonStyle(.borderedProminent)

                if session.mode == .flat {
                    Menu("Face", systemImage: "cube") {
                        ForEach(CubeFace.allCases, id: \.self) { face in
                            Button(face.label) { session.showFace(face) }
                        }
                    }
                }
                if session.mode != .unfolded {
                    Toggle("Horizon verrouillé", isOn: Binding(get: { session.horizonLocked },
                                                              set: { session.setHorizonLocked($0) }))
                        .fixedSize()
                }
                if session.mode != .unfolded {
                    Text("Champ \(Int(session.fovDegrees))°")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 16) {
                ToolPicker(session: session)
                AdjustmentsMenu(session: session)

                Button {
                    session.showColorPicker = true
                } label: {
                    Circle()
                        .fill(Color(.sRGB, red: session.color.x, green: session.color.y, blue: session.color.z))
                        .frame(width: 30, height: 30)
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2))
                }
                .popover(isPresented: $session.showColorPicker) {
                    ColorPickerPanel(session: session)
                        .padding(18)
                }

                ToolOptions(session: session)
                SphereToolsMenus(session: session)

                Menu("Fusion : \(session.blendSpace.label)") {
                    ForEach(BlendSpace.allCases, id: \.self) { space in
                        Button(space.label) { session.setBlendSpace(space) }
                    }
                }

                Picker("Affichage", selection: $session.toneMapping) {
                    ForEach(ToneMapping.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Exposition \(session.exposure, format: .number.precision(.fractionLength(1))) EV")
                    Slider(value: $session.exposure, in: -4...4)
                }
                .frame(width: 170)
            }
        }
        .font(.callout)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

extension CanvasCoordinator: UIPencilInteractionDelegate {
    /// Double tap sur le Pencil 2, selon le réglage d'iPadOS (Réglages > Apple Pencil).
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        switch UIPencilInteraction.preferredTapAction {
        case .switchEraser, .switchPrevious:
            session.tool = session.tool == .eraser ? .brush : .eraser
            session.showToast(session.tool.label)
        case .showColorPalette:
            session.showColorPicker.toggle()
        case .showInkAttributes:
            session.showBrushes.toggle()
        default:
            break
        }
    }
}
