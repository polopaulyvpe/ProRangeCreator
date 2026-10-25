import PRCore
import SwiftUI

/// Sélecteur de couleur : carré saturation × luminosité, barre de teinte, saisie hexadécimale, couleurs récentes.
struct ColorPickerPanel: View {
    @Bindable var session: CanvasSession
    @State private var hsb: HSBColor
    @State private var hexText: String

    private static let squareSize = CGSize(width: 260, height: 200)
    private static let hueStops: [Color] = (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) }

    init(session: CanvasSession) {
        self.session = session
        _hsb = State(initialValue: HSBColor(rgb: session.color))
        _hexText = State(initialValue: HexColor.format(session.color))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            saturationBrightnessSquare
            hueBar
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(swatch(session.color))
                    .frame(width: 44, height: 32)
                TextField("#RRGGBB", text: $hexText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .onSubmit(applyHex)
                    .frame(width: 120)
            }
            if !session.recentColors.isEmpty {
                Text("Récentes").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(Array(session.recentColors.enumerated()), id: \.offset) { _, c in
                        Button { set(c) } label: {
                            Circle().fill(swatch(c)).frame(width: 24, height: 24)
                        }
                    }
                }
            }
        }
        .frame(width: Self.squareSize.width)
    }

    private var saturationBrightnessSquare: some View {
        let size = Self.squareSize
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(hue: hsb.hue, saturation: 1, brightness: 1))
            LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
            Circle()
                .stroke(.white, lineWidth: 3)
                .shadow(radius: 2)
                .frame(width: 22, height: 22)
                .offset(x: hsb.saturation * size.width - 11, y: (1 - hsb.brightness) * size.height - 11)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            hsb.saturation = min(max(drag.location.x / size.width, 0), 1)
            hsb.brightness = 1 - min(max(drag.location.y / size.height, 0), 1)
            applyHSB()
        })
    }

    private var hueBar: some View {
        let width = Self.squareSize.width
        return ZStack(alignment: .leading) {
            LinearGradient(colors: Self.hueStops, startPoint: .leading, endPoint: .trailing)
                .clipShape(Capsule())
            Circle()
                .stroke(.white, lineWidth: 3)
                .shadow(radius: 2)
                .frame(width: 22, height: 22)
                .offset(x: hsb.hue * width - 11)
        }
        .frame(width: width, height: 24)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            hsb.hue = min(max(drag.location.x / width, 0), 0.9999)
            applyHSB()
        })
    }

    private func swatch(_ c: SIMD3<Double>) -> Color {
        Color(.sRGB, red: c.x, green: c.y, blue: c.z)
    }

    private func applyHSB() {
        session.color = hsb.rgb
        hexText = HexColor.format(session.color)
    }

    private func applyHex() {
        guard let c = HexColor.parse(hexText) else {
            hexText = HexColor.format(session.color)
            return
        }
        set(c)
    }

    private func set(_ c: SIMD3<Double>) {
        session.color = c
        hsb = HSBColor(rgb: c)
        hexText = HexColor.format(c)
    }
}
