import CrumbsCore
import SwiftUI

struct CrumbTable: View {
    @Environment(CrumbStore.self) private var store
    @State private var sortOrder = [KeyPathComparator(\Crumb.size, order: .reverse)]

    var body: some View {
        @Bindable var store = store
        Table(of: Crumb.self, selection: $store.focused, sortOrder: $sortOrder) {
            TableColumn("") { crumb in
                if crumb.isGroup {
                    let pickable = pickable(in: crumb)
                    Toggle("", isOn: Binding(
                        get: { !pickable.isEmpty && pickable.isSubset(of: store.selection) },
                        set: { on in
                            if on { store.selection.formUnion(pickable) } else { store.selection.subtract(pickable) }
                        }))
                    .labelsHidden()
                    .disabled(pickable.isEmpty)
                    .help(pickable.isEmpty ? "Everything here is in use or holds unique work" : "Pick everything here that can go")
                } else {
                    Toggle("", isOn: Binding(
                        get: { store.selection.contains(crumb.id) },
                        set: { on in
                            if on { store.selection.insert(crumb.id) } else { store.selection.remove(crumb.id) }
                        }))
                    .labelsHidden()
                    .help(crumb.verdict == .keep ? "Marked Keep: in use or holds unique work. You can still pick it; Crumbs asks before it goes." : "")
                }
            }
            .width(22)

            TableColumn("Crumb", value: \.path) { crumb in
                HStack(spacing: 8) {
                    VerdictDot(verdict: crumb.verdict)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(crumb.name).lineLimit(1).fontWeight(crumb.isGroup ? .medium : .regular)
                        Text(Format.path(crumb.isGroup ? (crumb.project ?? "Temp folders, chats and other loose crumbs")
                                             : (crumb.path as NSString).deletingLastPathComponent))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .width(min: 170, ideal: 280)

            TableColumn("Size", value: \.size) { crumb in
                Text(Format.bytes(crumb.size)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(76)

            TableColumn("Idle", value: \.idleSort) { crumb in
                Text(Format.age(crumb.lastActivity)).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(70)

            TableColumn("Kind", value: \.ruleName) { crumb in
                Text(crumb.ruleName).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 140)

            TableColumn("Why", value: \.verdict.rawValue) { crumb in
                Text(crumb.reasons.first?.text ?? "").foregroundStyle(.secondary).lineLimit(1)
                    .help(crumb.reasons.first?.text ?? "")
            }
            .width(min: 90, ideal: 240)
        } rows: {
            if store.groupByProject {
                ForEach(store.visibleGroups.sorted { sortOrder.compare($0.header, $1.header) == .orderedAscending }) { group in
                    DisclosureTableRow(group.header) {
                        ForEach(group.members.sorted(using: sortOrder)) { crumb in
                            TableRow(crumb)
                        }
                    }
                }
            } else {
                ForEach(store.visible.sorted(using: sortOrder)) { crumb in
                    TableRow(crumb)
                }
            }
        }
        .contextMenu(forSelectionType: Crumb.ID.self) { ids in
            if let id = ids.first, let crumb = store.crumbs.first(where: { $0.id == id }) {
                Button("Reveal in Finder") { store.reveal(crumb) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(crumb.path, forType: .string)
                }
            }
        }
    }
}

extension CrumbTable {
    /// Ids under a repository row that are allowed to go.
    fileprivate func pickable(in header: Crumb) -> Set<Crumb.ID> {
        Set(store.visible.filter { $0.project == header.project && $0.verdict != .keep }.map(\.id))
    }
}

extension Crumb {
    var isGroup: Bool { ruleID == CrumbStore.groupRuleID }
    var idleSort: Double { -(lastActivity?.timeIntervalSince1970 ?? 0) }
}

struct VerdictDot: View {
    var verdict: Verdict

    var body: some View {
        Circle()
            .fill(verdict.color)
            .frame(width: 9, height: 9)
            .accessibilityLabel(verdict.label)
    }
}

extension Verdict {
    var color: Color {
        switch self {
        case .safe: .green
        case .caution: .orange
        case .keep: .red
        }
    }
}
