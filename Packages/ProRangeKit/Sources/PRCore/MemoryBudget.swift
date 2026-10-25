public enum PixelFormat: String, CaseIterable, Sendable {
    case rgba8
    case rgba16Float
    case rgba32Float

    public var bytesPerPixel: Int {
        switch self {
        case .rgba8: 4
        case .rgba16Float: 8
        case .rgba32Float: 16
        }
    }
}

/// Résolution équirectangulaire 2:1.
public struct CanvasResolution: Hashable, Sendable {
    public let width: Int
    public var height: Int { width / 2 }
    public var pixelCount: Int { width * height }

    public init(width: Int) {
        precondition(width > 0 && width % 2 == 0)
        self.width = width
    }

    public static let k2 = CanvasResolution(width: 2048)
    public static let k4 = CanvasResolution(width: 4096)
    public static let k8 = CanvasResolution(width: 8192)
    public static let k16 = CanvasResolution(width: 16384)
    public static let presets: [CanvasResolution] = [.k2, .k4, .k8, .k16]

    public var label: String { "\(width / 1024)K" }

    public func bytesPerFullLayer(_ format: PixelFormat) -> Int { pixelCount * format.bytesPerPixel }
}

/// Nombre de calques garanti dans le pire cas (tous les calques entièrement peints et résidents en mémoire).
/// Le stockage épars et le déversement sur disque permettent souvent d'aller au-delà ; c'est le plancher affiché à l'utilisateur.
public struct MemoryBudget: Sendable {
    public static let maxLayers = 50

    /// Mémoire disponible pour l'app (`os_proc_available_memory` au lancement).
    public var availableBytes: Int
    /// Réserve pour l'app, l'interface, le pilote Metal et la pyramide d'affichage.
    public var fixedOverheadBytes: Int
    /// Équivalents « calque plein » pour la composition : cache dessous, cache dessus, tampon de trait.
    public var workingLayerEquivalents: Int

    public init(availableBytes: Int, fixedOverheadBytes: Int = 400 << 20, workingLayerEquivalents: Int = 3) {
        self.availableBytes = availableBytes
        self.fixedOverheadBytes = fixedOverheadBytes
        self.workingLayerEquivalents = workingLayerEquivalents
    }

    public func guaranteedLayers(_ resolution: CanvasResolution, _ format: PixelFormat) -> Int {
        let usable = availableBytes - fixedOverheadBytes
        guard usable > 0 else { return 0 }
        let fit = usable / resolution.bytesPerFullLayer(format) - workingLayerEquivalents
        return min(Self.maxLayers, max(0, fit))
    }
}
