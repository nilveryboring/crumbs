import CrumbsCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            RulesSettings()
                .tabItem { Label("Rules", systemImage: "slider.horizontal.3") }
            FolderSettings()
                .tabItem { Label("Folders", systemImage: "folder") }
        }
    }
}

private struct RulesSettings: View {
    @Environment(CrumbStore.self) private var store
    private static let dayChoices = [1, 3, 7, 14, 30, 60, 90, 180, 365]

    var body: some View {
        Form {
            Section {
                Text("A crumb becomes safe once it has been idle this long. Newer ones are marked Check. Anything changed in the last 24 hours, in use, or holding uncommitted work is always kept.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(CrumbCategory.allCases, id: \.self) { category in
                let rules = store.builtInRules.filter { $0.category == category }
                if !rules.isEmpty {
                    Section(category.label) {
                        ForEach(rules, id: \.id) { rule in row(rule) }
                    }
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { store.overrides = [:] }
                        .disabled(store.overrides.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ rule: Rule) -> some View {
        let enabled = Binding(
            get: { store.overrides[rule.id]?.enabled ?? true },
            set: { store.setOverride(rule.id, enabled: $0) })
        let days = Binding(
            get: { store.overrides[rule.id]?.minIdleDays ?? rule.minIdleDays },
            set: { store.setOverride(rule.id, minIdleDays: $0) })
        let choices = Array(Set(Self.dayChoices + [rule.minIdleDays, days.wrappedValue])).sorted()

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                Text(rule.description)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(enabled.wrappedValue ? 1 : 0.5)
            Spacer(minLength: 8)
            Picker("Safe after", selection: days) {
                ForEach(choices, id: \.self) { n in
                    Text(n == rule.minIdleDays ? "\(label(n)) (default)" : label(n)).tag(n)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!enabled.wrappedValue)
            .help("Safe after this many idle days")
            Toggle("Find \(rule.name)", isOn: enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func label(_ days: Int) -> String {
        switch days {
        case 1: "1 day"
        case 365: "1 year"
        default: "\(days) days"
        }
    }
}

private struct FolderSettings: View {
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
