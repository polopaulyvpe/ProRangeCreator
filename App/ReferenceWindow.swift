import PhotosUI
import PRCore
import SwiftUI
import UIKit

/// Ce que montre la fenêtre de référence.
enum ReferenceMode: String, CaseIterable {
    /// Toute la toile dépliée, avec l'endroit regardé : on y voit ce qui est derrière soi.
    case canvas
    /// Une photo choisie par Paul.
    case image

    var label: String { self == .canvas ? "Toile" : "Image" }
}

extension CanvasSession {
    /// Image RGBA 8 bits (sRGB prémultiplié) en `CGImage`.
    static func cgImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Redessine la vue d'ensemble un peu après la dernière opération (une seule fois pour une rafale).
    func scheduleReferenceRefresh() {
        guard showReference, referenceMode == .canvas else { return }
        referenceTask?.cancel()
        referenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            if let rgba = self.renderUnfolded(width: 512, height: 256) {
                self.referenceCanvas = Self.cgImage(rgba: rgba, width: 512, height: 256)
            }
        }
    }

    /// Toucher la vue d'ensemble : la vue se tourne vers cet endroit.
    func lookAtReference(u: Double, v: Double) {
        var look = view.capturedLook
        look.yaw = (u - 0.5) * 2 * .pi
        look.pitch = min(1.55, max(-1.55, (0.5 - v) * .pi))
        go(to: look)
    }
}

/// Fenêtre flottante, déplaçable : la toile entière dépliée (avec le regard) ou une photo de référence.
struct ReferenceWindow: View {
    @Bindable var session: CanvasSession
    @State private var offset = CGSize(width: 0, height: 0)
    @State private var dragStart: CGSize?
    @State private var photo: PhotosPickerItem?
    private let width: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(width: width, height: width / 2)
                .clipped()
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.12)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.25)))
        .shadow(radius: 8)
        .offset(offset)
        .onAppear { session.scheduleReferenceRefresh() }
        .onChange(of: session.referenceMode) { _, _ in session.scheduleReferenceRefresh() }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data)?.cgImage {
                    session.referencePhoto = image
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.white.opacity(0.6))
            Picker("Référence", selection: $session.referenceMode) {
                ForEach(ReferenceMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            if session.referenceMode == .image {
                PhotosPicker(selection: $photo, matching: .images) { Image(systemName: "photo") }
            }
            Spacer()
            Button { session.showReference = false } label: { Image(systemName: "xmark.circle.fill") }
        }
        .font(.system(size: 17))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .gesture(DragGesture(coordinateSpace: .global)
            .onChanged { drag in
                let start = dragStart ?? offset
                dragStart = start
                offset = CGSize(width: start.width + drag.translation.width, height: start.height + drag.translation.height)
            }
            .onEnded { _ in dragStart = nil })
    }

    @ViewBuilder private var content: some View {
        switch session.referenceMode {
        case .canvas:
            if let image = session.referenceCanvas {
                GeometryReader { geo in
                    let _ = session.viewRevision
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .overlay { marker(in: geo.size) }
                        .contentShape(Rectangle())
                        .onTapGesture { p in
                            session.lookAtReference(u: Double(p.x / geo.size.width), v: Double(p.y / geo.size.height))
                        }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .image:
            if let photo = session.referencePhoto {
                Image(decorative: photo, scale: 1).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Choisis une photo avec le bouton image.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// L'endroit regardé, sur la vue d'ensemble.
    private func marker(in size: CGSize) -> some View {
        let center = session.view.direction(atNDC: .zero, aspect: session.lastAspect) ?? [0, 0, -1]
        let uv = Equirect.uv(from: center)
        return Circle()
            .stroke(Color.white, lineWidth: 2)
            .background(Circle().stroke(Color.black.opacity(0.6), lineWidth: 4))
            .frame(width: 16, height: 16)
            .position(x: CGFloat(uv.x) * size.width, y: CGFloat(uv.y) * size.height)
            .allowsHitTesting(false)
    }
}
