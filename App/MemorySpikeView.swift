import Metal
import PRCore
import PREngine
import SwiftUI

/// Spike mémoire : budget théorique par résolution, puis allocation réelle de textures pleine toile sur le GPU.
struct MemorySpikeView: View {
    @State private var stress = TextureStressTest()
    @State private var available = MemoryProbe.availableBytes
    @State private var log: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("GPU : \(stress.deviceName)")
                Text("Mémoire disponible pour l'app : \(format(available))")
                    .font(.title3.monospacedDigit())
                Text("Textures allouées par le test : \(stress.textures.count) · \(format(stress.allocatedBytes))")
                    .monospacedDigit()

                budgetTable

                Text("Allocation réelle")
                    .font(.headline)
                Text("Ajoute des textures pleine toile jusqu'à l'échec. Si iPadOS ferme l'app, la dernière ligne du journal est la limite mesurée.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("+1 calque 16K RGBA16F") { allocate(.k16, .rgba16Float) }
                    Button("+1 calque 8K RGBA16F") { allocate(.k8, .rgba16Float) }
                    Button("+1 calque 16K RGBA8") { allocate(.k16, .rgba8Unorm) }
                    Button("Tout libérer", role: .destructive) {
                        stress.releaseAll()
                        log.append("Libéré · disponible \(format(MemoryProbe.availableBytes))")
                    }
                }
                .buttonStyle(.bordered)

                ForEach(Array(log.enumerated().reversed()), id: \.offset) { entry in
                    Text(entry.element)
                        .font(.footnote.monospaced())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .task {
            while !Task.isCancelled {
                available = MemoryProbe.availableBytes
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var budgetTable: some View {
        let budget = MemoryBudget(availableBytes: available ?? 0)
        return Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            GridRow {
                Text("Toile").bold()
                ForEach(PixelFormat.allCases, id: \.self) { Text($0.rawValue).bold() }
            }
            ForEach(CanvasResolution.presets, id: \.self) { res in
                GridRow {
                    Text("\(res.label) (\(res.width)×\(res.height))")
                    ForEach(PixelFormat.allCases, id: \.self) { f in
                        Text("\(format(res.bytesPerFullLayer(f))) · \(budget.guaranteedLayers(res, f)) calques garantis")
                            .monospacedDigit()
                    }
                }
            }
        }
        .font(.callout)
    }

    private func allocate(_ res: CanvasResolution, _ format: MTLPixelFormat) {
        let label = "\(res.label) \(format == .rgba16Float ? "RGBA16F" : "RGBA8")"
        switch stress.allocate(width: res.width, height: res.height, format: format) {
        case .success(let duration):
            log.append("+ \(label) en \(duration.formatted(.units(allowed: [.milliseconds]))) · total \(stress.textures.count) · disponible \(self.format(MemoryProbe.availableBytes))")
        case .failure(let error):
            log.append("✗ \(label) : \(error) · disponible \(self.format(MemoryProbe.availableBytes))")
        }
    }

    private func format(_ bytes: Int?) -> String {
        guard let bytes else { return "inconnue" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
