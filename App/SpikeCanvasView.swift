import PRCore
import simd
import SwiftUI

struct PaletteColor: Identifiable, Sendable {
    let name: String
    /// sRGB encodé.
    let rgb: SIMD3<Float>
    var id: String { name }

    static let all: [PaletteColor] = [
        PaletteColor(name: "Bleu", rgb: [0.15, 0.35, 0.85]),
        PaletteColor(name: "Orange", rgb: [0.95, 0.55, 0.15]),
        PaletteColor(name: "Noir", rgb: [0.05, 0.05, 0.05]),
        PaletteColor(name: "Blanc", rgb: [1, 1, 1]),
    ]
}

/// Toile CPU 2K dépliée. Sert à vérifier à l'œil que le pinceau est rond sur la sphère
/// (donc étiré à plat près des pôles) et qu'il passe la couture sans raccord.
@MainActor
@Observable
final class SpikeCanvasModel {
    static let width = 2048
    static let height = 1024

    var radiusDegrees = 6.0
    var hardness = 0.7
    var screenSpaceFootprint = false
    var colorIndex = 0
    private(set) var image: CGImage?
    private(set) var lastStrokeMilliseconds = 0.0

    private let canvas = EquirectCanvas(width: SpikeCanvasModel.width, height: SpikeCanvasModel.height, fill: [1, 1, 1, 1])
    @ObservationIgnored private var rgba = [UInt8](repeating: 0, count: SpikeCanvasModel.width * SpikeCanvasModel.height * 4)
    @ObservationIgnored private var sampler = SphericalStrokeSampler()
    @ObservationIgnored private var lastPixel: SIMD2<Double>?
    @ObservationIgnored private var carryPixels = 0.0

    init() {
        refresh(rows: 0...(Self.height - 1))
    }

    private var radius: Double { radiusDegrees * .pi / 180 }
    private var spacing: Double { radius * 0.15 }
    private var radiusPixels: Double { radiusDegrees / 360 * Double(Self.width) }

    private var linearColor: SIMD4<Float> {
        let c = PaletteColor.all[colorIndex].rgb
        return [ColorTransfer.toLinear(c.x), ColorTransfer.toLinear(c.y), ColorTransfer.toLinear(c.z), 1]
    }

    func strokeBegan(uv: SIMD2<Double>) {
        if screenSpaceFootprint {
            let p = pixel(uv)
            lastPixel = p
            carryPixels = 0
            measure { stampScreen([p]) }
        } else {
            let d = Equirect.direction(u: uv.x, v: uv.y)
            measure { stampSphere(sampler.begin(at: d)) }
        }
    }

    func strokeMoved(uv: SIMD2<Double>) {
        if screenSpaceFootprint {
            guard let a = lastPixel else { return strokeBegan(uv: uv) }
            let b = pixel(uv)
            let step = radiusPixels * 0.15
            let total = simd_length(b - a)
            var points: [SIMD2<Double>] = []
            var s = step - carryPixels
            while s <= total {
                points.append(a + (b - a) * (s / total))
                s += step
            }
            carryPixels = total - (s - step)
            lastPixel = b
            measure { stampScreen(points) }
        } else {
            let d = Equirect.direction(u: uv.x, v: uv.y)
            let centers = sampler.add(d, spacing: spacing)
            measure { stampSphere(centers) }
        }
    }

    func strokeEnded() {
        lastPixel = nil
    }

    /// Tampons de test à 0°, 30°, 60°, 75°, 85°, 90° et sur la couture.
    func stampTestGrid() {
        let points: [(Double, Double)] = [(0, 0), (30, 0), (60, 0), (75, 0), (85, 0), (90, 0),
                                          (-45, 0), (-80, 0), (0, 180), (45, 180), (-60, 180)]
        let centers = points.map { Equirect.direction(latitude: $0.0 * .pi / 180, longitude: $0.1 * .pi / 180) }
        measure { stampSphere(centers) }
    }

    func clear() {
        canvas.clear(to: [1, 1, 1, 1])
        refresh(rows: 0...(Self.height - 1))
    }

    private func pixel(_ uv: SIMD2<Double>) -> SIMD2<Double> {
        [uv.x * Double(Self.width), uv.y * Double(Self.height)]
    }

    private func stampSphere(_ centers: [Vec3]) {
        var dirty: ClosedRange<Int>?
        for c in centers {
            let dab = SphericalDab(center: c, radius: radius, hardness: hardness, color: linearColor)
            if let rows = SphericalRasterizer.stamp(dab, on: canvas) { dirty = union(dirty, rows) }
        }
        if let dirty { refresh(rows: dirty) }
    }

    private func stampScreen(_ points: [SIMD2<Double>]) {
        var dirty: ClosedRange<Int>?
        for p in points {
            if let rows = SphericalRasterizer.stampScreenSpace(center: p, radiusPixels: radiusPixels, hardness: hardness,
                                                               color: linearColor, on: canvas) {
                dirty = union(dirty, rows)
            }
        }
        if let dirty { refresh(rows: dirty) }
    }

    private func union(_ a: ClosedRange<Int>?, _ b: ClosedRange<Int>) -> ClosedRange<Int> {
        guard let a else { return b }
        return min(a.lowerBound, b.lowerBound)...max(a.upperBound, b.upperBound)
    }

    private func measure(_ work: () -> Void) {
        let start = ContinuousClock.now
        work()
        let elapsed = ContinuousClock.now - start
        lastStrokeMilliseconds = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
    }

    private func refresh(rows: ClosedRange<Int>) {
        canvas.encodeSRGB8(rows: rows, into: &rgba)
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        image = CGImage(width: Self.width, height: Self.height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: Self.width * 4, space: space,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

struct SpikeCanvasView: View {
    @State private var model = SpikeCanvasModel()
    @State private var isDrawing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            controls
            GeometryReader { geo in
                let size = fittedSize(in: geo.size)
                ZStack {
                    if let image = model.image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.medium)
                    }
                    guides
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            let u = Double(value.location.x / size.width)
                            let v = Double(value.location.y / size.height)
                            let uv = SIMD2<Double>(min(max(u, 0), 0.999_999), min(max(v, 0), 1))
                            if isDrawing {
                                model.strokeMoved(uv: uv)
                            } else {
                                isDrawing = true
                                model.strokeBegan(uv: uv)
                            }
                        }
                        .onEnded { _ in
                            isDrawing = false
                            model.strokeEnded()
                        }
                )
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            Text("Dernier lot de dabs : \(model.lastStrokeMilliseconds, format: .number.precision(.fractionLength(1))) ms · toile 2K CPU (référence, pas le moteur Metal)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var controls: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading) {
                Text("Rayon : \(model.radiusDegrees, format: .number.precision(.fractionLength(1)))°")
                Slider(value: $model.radiusDegrees, in: 1...45)
            }
            .frame(maxWidth: 220)
            VStack(alignment: .leading) {
                Text("Dureté : \(Int(model.hardness * 100)) %")
                Slider(value: $model.hardness, in: 0...1)
            }
            .frame(maxWidth: 220)
            Picker("Couleur", selection: $model.colorIndex) {
                ForEach(PaletteColor.all.indices, id: \.self) { Text(PaletteColor.all[$0].name).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
            Toggle("Empreinte écran", isOn: $model.screenSpaceFootprint)
                .fixedSize()
            Button("Grille de test") { model.stampTestGrid() }
            Button("Effacer", role: .destructive) { model.clear() }
        }
    }

    /// Équateur et méridien central en pointillés, ±60° en trait fin.
    private var guides: some View {
        GeometryReader { geo in
            Path { p in
                let h = geo.size.height
                p.move(to: CGPoint(x: 0, y: h / 2))
                p.addLine(to: CGPoint(x: geo.size.width, y: h / 2))
                p.move(to: CGPoint(x: geo.size.width / 2, y: 0))
                p.addLine(to: CGPoint(x: geo.size.width / 2, y: h))
            }
            .stroke(.gray.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
            Path { p in
                for lat: CGFloat in [60, -60] {
                    let y: CGFloat = (90 - lat) / 180 * geo.size.height
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(.gray.opacity(0.35), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    private func fittedSize(in available: CGSize) -> CGSize {
        let width = min(available.width, available.height * 2)
        return CGSize(width: width, height: width / 2)
    }
}
