import CrumbsCore
import SwiftUI

struct CrumbTable: View {
    @Environment(CrumbStore.self) private var store
    @State private var sortOrder = [KeyPathComparator(\Crumb.size, order: .reverse)]

    var body: some View {
        @Bindable var store = store
        Table(of: Crumb.self, selection: $store.focused, sortOrder: $sortOrder) {
            TableColumn("") { crumb in
                Toggle("", isOn: Binding(
                    get: { store.selection.contains(crumb.id) },
                    set: { on in
                        if on { store.selection.insert(crumb.id) } else { store.selection.remove(crumb.id) }
                    }))
                .labelsHidden()
                .disabled(crumb.verdict == .keep)
                .help(crumb.verdict == .keep ? "In use or holds unique work" : "")
            }
            .width(22)

            TableColumn("Crumb", value: \.path) { crumb in
                HStack(spacing: 8) {
                    VerdictDot(verdict: crumb.verdict)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(crumb.name).lineLimit(1)
                        Text(Format.path((crumb.path as NSString).deletingLastPathComponent))
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
            ForEach(store.visible.sorted(using: sortOrder)) { crumb in
                TableRow(crumb)
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

extension Crumb {
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
