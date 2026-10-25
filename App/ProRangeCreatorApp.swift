import SwiftUI

@main
struct ProRangeCreatorApp: App {
    var body: some Scene {
        WindowGroup {
            SpikeRootView()
                .preferredColorScheme(.dark)
        }
    }
}

/// Écran temporaire du spike de phase 1 : pinceau sphérique et mesure mémoire.
struct SpikeRootView: View {
    var body: some View {
        TabView {
            CanvasScreen()
                .tabItem { Label("Toile", systemImage: "globe") }
            SpikeCanvasView()
                .tabItem { Label("Pinceau 2D", systemImage: "paintbrush.pointed") }
            MemorySpikeView()
                .tabItem { Label("Mémoire", systemImage: "memorychip") }
        }
    }
}
