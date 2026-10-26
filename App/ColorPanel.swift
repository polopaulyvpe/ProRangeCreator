import PRCore
import SwiftUI

/// Onglets du panneau Couleurs (même organisation que Procreate).
enum ColorTab: String, CaseIterable {
    case disc, classic, harmony, value, palettes

    var label: String {
        switch self {
        case .disc: "Disque"
        case .classic: "Classique"
        case .harmony: "Harmonie"
        case .value: "Valeur"
        case .palettes: "Palettes"
        }
    }

    var symbol: String {
        switch self {
        case .disc: "circle"
        case .classic: "square.fill"
        case .harmony: "point.3.connected.trianglepath.dotted"
        case .value: "slider.horizontal.3"
        case .palettes: "square.grid.3x3.fill"
        }
    }
}

/// Accords de couleurs de l'onglet Harmonie : décalages de teinte autour de la couleur courante.
enum ColorHarmony: String, CaseIterable {
    case complementary, splitComplementary, analogous, triadic, tetradic

    var label: String {
        switch self {
        case .complementary: "Complémentaire"
        case .splitComplementary: "Complémentaires adjacentes"
        case .analogous: "Analogue"
        case .triadic: "Triade"
        case .tetradic: "Tétradique"
        }
    }

    var offsets: [Double] {
        switch self {
        case .complementary: [0, 0.5]
        case .splitComplementary: [0, 0.4167, 0.5833]
        case .analogous: [0, -0.0833, 0.0833]
        case .triadic: [0, 0.3333, 0.6667]
        case .tetradic: [0, 0.25, 0.5, 0.75]
        }
    }
}

/// Palettes fournies (générées, aucun contenu repris) pour peindre ciels et paysages.
private let builtInPalettes: [(String, [SIMD3<Double>])] = [
    ("Ciel de jour", (0..<10).map { i in HSBColor(hue: 0.58, saturation: 0.15 + 0.07 * Double(i), brightness: 1 - 0.05 * Double(i)).rgb }),
    ("Coucher de soleil", (0..<10).map { i in HSBColor(hue: 0.0 + 0.012 * Double(i) - (i > 6 ? 0.25 : 0), saturation: 0.55 + 0.04 * Double(i), brightness: 1 - 0.06 * Double(i)).rgb }),
    ("Nuit", (0..<10).map { i in HSBColor(hue: 0.64 + 0.01 * Double(i), saturation: 0.55, brightness: 0.05 + 0.06 * Double(i)).rgb }),
    ("Terre et végétation", (0..<10).map { i in HSBColor(hue: 0.08 + 0.025 * Double(i), saturation: 0.45, brightness: 0.25 + 0.05 * Double(i)).rgb }),
    ("Gris", (0..<10).map { i in HSBColor(hue: 0, saturation: 0, brightness: Double(i) / 9).rgb }),
]

struct ColorPanel: View {
    @Bindable var session: CanvasSession
    @State private var tab: ColorTab = .classic
    @State private var hsb: HSBColor
    @State private var harmony: ColorHarmony = .complementary
    @State private var hexText: String
    private let previous: SIMD3<Double>

    init(session: CanvasSession) {
        self.session = session
        _hsb = State(initialValue: HSBColor(rgb: session.color))
        _hexText = State(initialValue: HexColor.format(session.color))
        previous = session.recentColors.first ?? session.color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Couleurs").font(.system(size: 28, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                RoundedRectangle(cornerRadius: 8).fill(swatch(session.color)).frame(width: 64, height: 34)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.3)))
                Button { set(previous) } label: {
                    RoundedRectangle(cornerRadius: 8).fill(swatch(previous)).frame(width: 64, height: 34)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.3)))
                }
                .buttonStyle(.plain)
            }
            Group {
                switch tab {
                case .disc: disc
                case .classic: classic
                case .harmony: harmonyView
                case .value: valueView
                case .palettes: palettes
                }
            }
            .frame(minHeight: 330, alignment: .top)
            if tab != .palettes { historyRow }
            HStack(spacing: 0) {
                ForEach(ColorTab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        VStack(spacing: 4) {
                            Image(systemName: t.symbol).font(.system(size: 20))
                            Text(t.label).font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(tab == t ? Color.accentColor : .white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(Color(white: 0.2))
        .environment(\.colorScheme, .dark)
        .presentationCompactAdaptation(.popover)
        .onChange(of: session.color) { _, c in
            hexText = HexColor.format(c)
        }
    }

    // MARK: - Onglets

    private var classic: some View {
        VStack(spacing: 18) {
            SaturationBrightnessField(hsb: $hsb, onChange: apply)
                .frame(height: 230)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            GradientSlider(value: $hsb.hue, colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) }, onChange: apply)
            GradientSlider(value: $hsb.saturation,
                           colors: [Color(hue: hsb.hue, saturation: 0, brightness: hsb.brightness),
                                    Color(hue: hsb.hue, saturation: 1, brightness: hsb.brightness)], onChange: apply)
            GradientSlider(value: $hsb.brightness,
                           colors: [.black, Color(hue: hsb.hue, saturation: hsb.saturation, brightness: 1)], onChange: apply)
        }
    }

    private var disc: some View {
        HueRing(hsb: $hsb, onChange: apply) {
            SaturationBrightnessField(hsb: $hsb, onChange: apply)
                .clipShape(Circle())
        }
        .frame(width: 320, height: 320)
        .frame(maxWidth: .infinity)
    }

    private var harmonyView: some View {
        VStack(spacing: 16) {
            Picker("Accord", selection: $harmony) {
                ForEach(ColorHarmony.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            HueRing(hsb: $hsb, onChange: apply) {
                SaturationBrightnessField(hsb: $hsb, onChange: apply).clipShape(Circle())
            }
            .frame(width: 230, height: 230)
            HStack(spacing: 10) {
                ForEach(Array(harmony.offsets.enumerated()), id: \.offset) { _, offset in
                    let h = hsb.hue + offset
                    let c = HSBColor(hue: h - floor(h), saturation: hsb.saturation, brightness: hsb.brightness).rgb
                    Button { set(c) } label: {
                        RoundedRectangle(cornerRadius: 8).fill(swatch(c)).frame(height: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var valueView: some View {
        VStack(alignment: .leading, spacing: 12) {
            valueSlider("Teinte", value: $hsb.hue, scale: 360, unit: "°")
            valueSlider("Saturation", value: $hsb.saturation, scale: 100, unit: " %")
            valueSlider("Luminosité", value: $hsb.brightness, scale: 100, unit: " %")
            Divider()
            rgbSlider("Rouge", 0)
            rgbSlider("Vert", 1)
            rgbSlider("Bleu", 2)
            HStack {
                Text("Hexadécimal").foregroundStyle(.white.opacity(0.75))
                Spacer()
                TextField("#RRGGBB", text: $hexText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .frame(width: 130)
                    .onSubmit {
                        if let c = HexColor.parse(hexText) { set(c) } else { hexText = HexColor.format(session.color) }
                    }
            }
        }
    }

    private var palettes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                historyRow
                ForEach(builtInPalettes, id: \.0) { name, colors in
                    Text(name).font(.headline).foregroundStyle(.white.opacity(0.8))
                    swatchStrip(colors)
                }
            }
        }
        .frame(height: 330)
    }

    private var historyRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Historique").font(.headline).foregroundStyle(.white.opacity(0.8))
                Spacer()
                Button("Effacer") { session.recentColors.removeAll() }
                    .font(.callout)
                    .buttonStyle(.bordered)
            }
            swatchStrip(session.recentColors)
        }
    }

    private func swatchStrip(_ colors: [SIMD3<Double>]) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<10, id: \.self) { i in
                if i < colors.count {
                    Button { set(colors[i]) } label: { Rectangle().fill(swatch(colors[i])) }
                        .buttonStyle(.plain)
                } else {
                    Rectangle().fill(Color(white: 0.28))
                }
            }
        }
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func valueSlider(_ title: String, value: Binding<Double>, scale: Double, unit: String) -> some View {
        HStack {
            Text(title).frame(width: 100, alignment: .leading).foregroundStyle(.white.opacity(0.75))
            Slider(value: value, in: 0...1) { _ in apply() }
                .onChange(of: value.wrappedValue) { _, _ in apply() }
            Text("\(Int((value.wrappedValue * scale).rounded()))\(unit)").monospacedDigit().frame(width: 56, alignment: .trailing)
        }
    }

    private func rgbSlider(_ title: String, _ index: Int) -> some View {
        let binding = Binding<Double>(
            get: { session.color[index] },
            set: { v in
                var c = session.color
                c[index] = v
                set(c)
            })
        return HStack {
            Text(title).frame(width: 100, alignment: .leading).foregroundStyle(.white.opacity(0.75))
            Slider(value: binding, in: 0...1)
            Text("\(Int((session.color[index] * 255).rounded()))").monospacedDigit().frame(width: 56, alignment: .trailing)
        }
    }

    // MARK: - Couleur courante

    private func apply() {
        session.color = hsb.rgb
    }

    private func set(_ c: SIMD3<Double>) {
        session.color = c
        hsb = HSBColor(rgb: c)
    }

    private func swatch(_ c: SIMD3<Double>) -> Color { Color(.sRGB, red: c.x, green: c.y, blue: c.z) }
}

/// Carré saturation (x) × luminosité (y), avec sa poignée.
struct SaturationBrightnessField: View {
    @Binding var hsb: HSBColor
    let onChange: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(hue: hsb.hue, saturation: 1, brightness: 1))
                LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                Circle()
                    .stroke(.white, lineWidth: 3)
                    .shadow(radius: 2)
                    .frame(width: 26, height: 26)
                    .offset(x: hsb.saturation * geo.size.width - 13, y: (1 - hsb.brightness) * geo.size.height - 13)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                hsb.saturation = min(1, max(0, Double(g.location.x / geo.size.width)))
                hsb.brightness = min(1, max(0, 1 - Double(g.location.y / geo.size.height)))
                onChange()
            })
        }
    }
}

/// Anneau de teinte autour d'un contenu (disque saturation × luminosité).
struct HueRing<Inner: View>: View {
    @Binding var hsb: HSBColor
    let onChange: () -> Void
    @ViewBuilder let inner: Inner

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let ring = side * 0.12
            let angle = Angle(degrees: hsb.hue * 360 - 90)
            ZStack {
                Circle()
                    .strokeBorder(AngularGradient(colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) },
                                                  center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)),
                                  lineWidth: ring)
                inner.frame(width: side - ring * 2 - 16, height: side - ring * 2 - 16)
                Circle().stroke(.white, lineWidth: 3).frame(width: ring - 4, height: ring - 4)
                    .offset(x: cos(angle.radians) * (side - ring) / 2, y: sin(angle.radians) * (side - ring) / 2)
            }
            .frame(width: side, height: side)
            .contentShape(Circle())
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { g in
                let dx = g.location.x - side / 2, dy = g.location.y - side / 2
                guard (dx * dx + dy * dy).squareRoot() > side / 2 - ring - 4 else { return }
                var h = (atan2(dy, dx) + .pi / 2) / (2 * .pi)
                if h < 0 { h += 1 }
                hsb.hue = Double(h)
                onChange()
            })
        }
    }
}

/// Glissière horizontale sur un dégradé, poignée ronde.
struct GradientSlider: View {
    @Binding var value: Double
    let colors: [Color]
    let onChange: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)).frame(height: 10)
                Capsule().fill(.white).frame(width: 26, height: 20).shadow(radius: 2)
                    .offset(x: value * (geo.size.width - 26))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                value = min(1, max(0, Double((g.location.x - 13) / (geo.size.width - 26))))
                onChange()
            })
        }
        .frame(height: 26)
    }
}
