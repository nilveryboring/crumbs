import CrumbsCore
import SwiftUI

struct CrumbDetail: View {
    @Environment(CrumbStore.self) private var store
    var crumb: Crumb

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        VerdictDot(verdict: crumb.verdict)
                        Text(crumb.verdict.headline).font(.headline)
                    }
                    Text(crumb.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(Format.path(crumb.path))
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    fact("Kind", crumb.ruleName)
                    fact("Size", "\(Format.bytes(crumb.size)) · \(crumb.fileCount.formatted()) files")
                    fact("Last change", crumb.lastActivity.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                    if let wt = crumb.worktree {
                        fact("Branch", wt.branch ?? (wt.isOrphaned ? "unknown" : "detached HEAD"))
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Why").font(.headline)
                    ForEach(crumb.reasons, id: \.self) { reason in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VerdictDot(verdict: reason.level)
                            Text(reason.text).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !crumb.secrets.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Secret-looking files").font(.headline)
                        ForEach(crumb.secrets, id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled) }
                    }
                }

                HStack {
                    Button("Reveal in Finder") { store.reveal(crumb) }
                    Spacer()
                    Button("Move to Trash", role: .destructive) { store.trash([crumb]) }
                        .disabled(crumb.verdict == .keep || store.isStale || store.isTrashing)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

extension Verdict {
    var headline: String {
        switch self {
        case .safe: "Safe to clear"
        case .caution: "Check before clearing"
        case .keep: "Keep"
        }
    }
}
