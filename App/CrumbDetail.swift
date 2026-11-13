import CrumbsCore
import SwiftUI

struct CrumbDetail: View {
    @Environment(CrumbStore.self) private var store
    var crumb: Crumb
    @State private var contents: (entries: [ContentEntry], more: Int)?
    @State private var atRisk: WorkAtRisk?

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

                if let atRisk, !atRisk.files.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Uncommitted here").font(.headline)
                        Text("These changes exist only in this folder.").font(.caption).foregroundStyle(.secondary)
                        ForEach(atRisk.files) { file in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(file.change).font(.caption).foregroundStyle(.secondary)
                                    .frame(width: 54, alignment: .leading)
                                Text(file.path).font(.callout.monospaced()).lineLimit(2).truncationMode(.middle)
                                    .textSelection(.enabled)
                                Spacer(minLength: 4)
                                if let added = file.added, let removed = file.removed {
                                    Text("+\(added) −\(removed)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if atRisk.moreFiles > 0 {
                            Text("and \(atRisk.moreFiles) more").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if let atRisk, !atRisk.commits.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(crumb.worktree?.branch == nil ? "Commits only in this checkout" : "Commits not merged or pushed")
                            .font(.headline)
                        ForEach(atRisk.commits, id: \.self) { commit in
                            Text(commit).font(.callout.monospaced()).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                        }
                        if atRisk.moreCommits > 0 {
                            Text("and \(atRisk.moreCommits) more").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if let contents {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What's inside").font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                            ForEach(contents.entries) { entry in
                                GridRow {
                                    Image(systemName: entry.isDirectory ? "folder" : "doc").foregroundStyle(.secondary)
                                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                                    Text(Format.bytes(entry.size)).monospacedDigit().foregroundStyle(.secondary)
                                        .gridColumnAlignment(.trailing)
                                    Text(Format.age(entry.modified)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .font(.callout)
                        if contents.more > 0 {
                            Text("and \(contents.more) smaller item\(contents.more == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
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
                    Button("Delete…", role: .destructive) {
                        store.selection = [crumb.id]
                        store.confirmation = .delete
                    }
                    .disabled(store.isStale || store.isTrashing)
                    .help("Delete for good, skipping the Trash. Asks first.")
                    Button(crumb.verdict == .keep ? "Move to Trash Anyway…" : "Move to Trash", role: .destructive) {
                        if crumb.verdict == .keep {
                            store.selection = [crumb.id]
                            store.confirmation = .trash
                        } else {
                            store.trash([crumb])
                        }
                    }
                    .disabled(store.isStale || store.isTrashing)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: crumb.id) {
            contents = nil
            atRisk = nil
            guard crumb.codexSessionID == nil else { return } // a chat is one file
            let path = crumb.path
            if let info = crumb.worktree {
                let risk = await Task.detached(priority: .userInitiated) { WorkAtRisk.inspect(worktree: path, info: info) }.value
                if !Task.isCancelled, !risk.isEmpty { atRisk = risk }
            }
            let found = await Task.detached(priority: .utility) { ContentsInspector.topLevel(of: path) }.value
            if !Task.isCancelled, !found.entries.isEmpty { contents = found }
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
