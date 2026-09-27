import CrumbsCore
import SwiftUI

struct SettingsView: View {
    @Environment(CrumbStore.self) private var store
    @State private var picked: String?

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                List(selection: $picked) {
                    ForEach(store.roots, id: \.self) { root in
                        Label(Format.path(root), systemImage: "folder").tag(root)
                    }
                }
                .frame(minHeight: 180)
                HStack {
                    Button("Add Folder…", action: addFolder)
                    Button("Remove") {
                        store.roots.removeAll { $0 == picked }
                        picked = nil
                    }
                    .disabled(picked == nil)
                    Spacer()
                    Button("Reset to Defaults") { store.roots = CrumbScanner.defaultRoots() }
                }
            } header: {
                Text("Folders to scan")
            } footer: {
                Text("Crumbs looks inside these folders for agent worktrees, dependencies, build output and scratch folders. It never follows symlinks and never deletes: everything goes to the Trash.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !store.roots.contains(url.path) {
            store.roots.append(url.path)
        }
    }
}
