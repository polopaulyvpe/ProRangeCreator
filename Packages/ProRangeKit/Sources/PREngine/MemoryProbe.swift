import Metal
import os

public enum MemoryProbe {
    /// Mémoire encore allouable par l'app avant que iPadOS ne la termine. `nil` hors iOS.
    public static var availableBytes: Int? {
        #if os(iOS)
        Int(os_proc_available_memory())
        #else
        nil
        #endif
    }
}

/// Spike mémoire : alloue des textures pleine toile jusqu'à l'échec, pour mesurer combien de calques tiennent réellement.
@MainActor
public final class TextureStressTest {
    public enum Failure: Error {
        case noDevice
        case allocationFailed
        case tooLarge(maxDimension: Int)
    }

    private let device: (any MTLDevice)?
    private let queue: (any MTLCommandQueue)?
    public private(set) var textures: [any MTLTexture] = []

    public init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
    }

    public var deviceName: String { device?.name ?? "aucun GPU" }

    public var allocatedBytes: Int { textures.reduce(0) { $0 + $1.allocatedSize } }

    /// Alloue une texture privée et l'efface sur le GPU pour forcer l'engagement réel de la mémoire.
    public func allocate(width: Int, height: Int, format: MTLPixelFormat) -> Result<Duration, Failure> {
        guard let device, let queue else { return .failure(.noDevice) }
        let maxDimension = 16384
        guard width <= maxDimension, height <= maxDimension else { return .failure(.tooLarge(maxDimension: maxDimension)) }

        let start = ContinuousClock.now
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        desc.storageMode = .private
        desc.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: desc) else { return .failure(.allocationFailed) }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return .failure(.allocationFailed) }
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { return .failure(.allocationFailed) }

        textures.append(texture)
        return .success(ContinuousClock.now - start)
    }

    public func releaseAll() {
        textures.removeAll()
    }
}
