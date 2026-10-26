import SwiftUI

@main
struct ProRangeCreatorApp: App {
    @State private var session = CanvasSession()

    var body: some Scene {
        WindowGroup {
            AppRootView(session: session)
        }
    }
}

/// La galerie au lancement (comme Procreate), puis la toile du projet ouvert.
struct AppRootView: View {
    @Bindable var session: CanvasSession

    var body: some View {
        Group {
            if session.showingGallery {
                GalleryScreen(session: session)
            } else {
                CanvasScreen(session: session)
            }
        }
        .preferredColorScheme(session.colorScheme)
        .task { session.applyLaunchPreferences() }
    }
}
