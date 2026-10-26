import PRCore
import PRStorage
import SwiftUI
import UIKit

extension CanvasSession {
    func listSnapshots() -> [ProjectLibrary.Snapshot] {
        guard let projectURL else { return [] }
        return Self.library.snapshots(of: projectURL)
    }

    /// Instantané nommé de l'état actuel (le projet est d'abord enregistré s'il ne l'a jamais été).
    func createSnapshot(named name: String) {
        strokeCancelled()
        if projectURL == nil { saveProject(silently: true) }
        guard let projectURL else { return }
        do {
            let snapshot = try Self.library.createSnapshot(named: name, stack: stack, of: projectURL, createdAt: projectCreatedAt)
            fileMessage = "Instantané « \(snapshot.name) » créé"
        } catch {
            fileMessage = "Instantané impossible : \(error.localizedDescription)"
        }
    }

    /// Revient à un instantané : son contenu remplace la toile (l'historique repart de zéro), le projet garde son nom.
    func restoreSnapshot(_ snapshot: ProjectLibrary.Snapshot) {
        strokeCancelled()
        do {
            let (_, loaded) = try ProjectPackage.loadStack(from: snapshot.url)
            replaceStack(loaded)
            scheduleAutosave()
            fileMessage = "Revenu à « \(snapshot.name) »"
        } catch {
            fileMessage = "Instantané illisible : \(error.localizedDescription)"
        }
    }
}

/// Galerie : vignettes des projets, ouvrir, dupliquer, renommer, supprimer.
struct GallerySheet: View {
    @Bindable var session: CanvasSession
    @Environment(\.dismiss) private var dismiss
    @State private var projects: [ProjectInfo] = []
    @State private var renaming: ProjectInfo?
    @State private var newName = ""
    @State private var deleting: ProjectInfo?

    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(projects) { project in
                        ProjectCard(project: project, isCurrent: project.url == session.projectURL)
                            .onTapGesture {
                                session.openProject(project)
                                dismiss()
                            }
                            .contextMenu {
                                Button("Ouvrir", systemImage: "folder") {
                                    session.openProject(project)
                                    dismiss()
                                }
                                Button("Dupliquer", systemImage: "plus.square.on.square") {
                                    session.duplicateProject(project)
                                    reload()
                                }
                                Button("Renommer", systemImage: "pencil") {
                                    newName = project.name
                                    renaming = project
                                }
                                Button("Supprimer", systemImage: "trash", role: .destructive) { deleting = project }
                            }
                    }
                }
                .padding()
                if projects.isEmpty {
                    Text("Aucun projet : ils apparaissent ici dès la première sauvegarde (automatique 30 s après une modification).")
                        .foregroundStyle(.secondary)
                        .padding()
                }
                if let message = session.fileMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary).padding(.bottom)
                }
            }
            .navigationTitle("Galerie")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Nouveau", systemImage: "plus") {
                        session.newProject()
                        dismiss()
                    }
                }
            }
            .onAppear(perform: reload)
            .alert("Renommer", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Nom", text: $newName)
                Button("Renommer") {
                    if let project = renaming { session.renameProject(project, to: newName) }
                    renaming = nil
                    reload()
                }
                Button("Annuler", role: .cancel) { renaming = nil }
            }
            .confirmationDialog("Supprimer ce projet et ses instantanés ?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Supprimer définitivement", role: .destructive) {
                    if let project = deleting { session.deleteProject(project) }
                    deleting = nil
                    reload()
                }
            }
        }
    }

    private func reload() { projects = session.listProjects() }
}

private struct ProjectCard: View {
    let project: ProjectInfo
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let image = UIImage(contentsOfFile: project.url.appendingPathComponent(ProjectLibrary.thumbnailName).path) {
                    Image(uiImage: image).resizable().aspectRatio(2, contentMode: .fit)
                } else {
                    Rectangle().fill(.quaternary).aspectRatio(2, contentMode: .fit)
                        .overlay(Image(systemName: "globe").font(.largeTitle).foregroundStyle(.secondary))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isCurrent ? Color.accentColor : .clear, lineWidth: 3))
            Text(project.name).font(.headline).lineLimit(1)
            Text(project.modified, style: .relative).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

/// Instantanés nommés du projet en cours.
struct SnapshotsSheet: View {
    @Bindable var session: CanvasSession
    @Environment(\.dismiss) private var dismiss
    @State private var snapshots: [ProjectLibrary.Snapshot] = []
    @State private var name = "Instantané"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Nom", text: $name)
                        Button("Créer") {
                            session.createSnapshot(named: name)
                            snapshots = session.listSnapshots()
                        }
                    }
                } footer: {
                    Text("Un instantané garde l'état actuel de tous les calques. Revenir à un instantané remplace la toile et vide l'historique.")
                }
                Section("Instantanés de « \(session.projectName) »") {
                    if snapshots.isEmpty { Text("Aucun instantané").foregroundStyle(.secondary) }
                    ForEach(snapshots) { snapshot in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(snapshot.name)
                                Text(snapshot.date, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Revenir") {
                                session.restoreSnapshot(snapshot)
                                dismiss()
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { try? CanvasSession.library.deleteSnapshot(snapshots[i]) }
                        snapshots = session.listSnapshots()
                    }
                }
                if let message = session.fileMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle("Instantanés")
            .toolbar { Button("Fermer") { dismiss() } }
            .onAppear { snapshots = session.listSnapshots() }
        }
    }
}
