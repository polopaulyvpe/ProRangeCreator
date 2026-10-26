import PhotosUI
import PRCore
import PRStorage
import SwiftUI

/// Écran d'accueil : tous les projets, comme la galerie de Procreate. Toucher une vignette ouvre la toile.
struct GalleryScreen: View {
    @Bindable var session: CanvasSession
    @State private var projects: [ProjectInfo] = []
    @State private var renaming: ProjectInfo?
    @State private var newName = ""
    @State private var deleting: ProjectInfo?
    @State private var showImporter = false
    @State private var photo: PhotosPickerItem?

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 28)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                Text("ProRange Creator").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                Spacer()
                Button("Importer") { showImporter = true }
                PhotosPicker("Photo", selection: $photo, matching: .images)
                Menu {
                    ForEach(Preferences.canvasWidths, id: \.self) { width in
                        Button("\(width / 1024)K — \(width) × \(width / 2)\(width == 4096 ? " (recommandé)" : width == 8192 ? " (lourd)" : "")") {
                            session.createProject(width: width)
                        }
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 24, weight: .regular))
                } primaryAction: {
                    session.createProject(width: session.preferences.canvasWidth)
                }
            }
            .font(.system(size: 18))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 28)
            .frame(height: 64)
            .background(Color(white: 0.12))

            ScrollView {
                if projects.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "globe").font(.system(size: 64)).foregroundStyle(.white.opacity(0.3))
                        Text("Aucun panorama pour l'instant").font(.title3).foregroundStyle(.white.opacity(0.7))
                        Button("Nouveau panorama") { session.createProject(width: session.preferences.canvasWidth) }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 160)
                }
                LazyVGrid(columns: columns, spacing: 34) {
                    ForEach(projects) { project in
                        ProjectCard(project: project, isCurrent: false)
                            .onTapGesture { session.openFromGallery(project) }
                            .contextMenu {
                                Button("Renommer", systemImage: "pencil") {
                                    newName = project.name
                                    renaming = project
                                }
                                Button("Dupliquer", systemImage: "plus.square.on.square") {
                                    session.duplicateProject(project)
                                    reload()
                                }
                                Button("Supprimer", systemImage: "trash", role: .destructive) { deleting = project }
                            }
                    }
                }
                .padding(28)
                if let message = session.fileMessage {
                    Text(message).font(.caption).foregroundStyle(.white.opacity(0.6)).padding(.bottom, 20)
                }
            }
        }
        .background(Color(white: 0.08).ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .onAppear(perform: reload)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importableTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            session.createProject(width: session.preferences.canvasWidth)
            session.loadImport(urls: urls)
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                session.createProject(width: session.preferences.canvasWidth)
                session.loadImport(data: data, name: "Photo")
            }
        }
        .alert("Renommer", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nom", text: $newName)
            Button("Renommer") {
                if let project = renaming { session.renameProject(project, to: newName) }
                renaming = nil
                reload()
            }
            Button("Annuler", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Supprimer ce panorama et ses instantanés ?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Supprimer définitivement", role: .destructive) {
                if let project = deleting { session.deleteProject(project) }
                deleting = nil
                reload()
            }
        }
    }

    private func reload() { projects = session.listProjects() }
}
