import CrumbsCore
import SwiftUI

struct ContentView: View {
    @Environment(CrumbStore.self) private var store
    @State private var confirming = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            VStack(spacing: 0) {
                SummaryHeader()
                Divider()
                if store.crumbs.isEmpty {
                    EmptyState()
                } else {
                    CrumbTable()
                }
                Divider()
                ActionBar(confirming: $confirming)
            }
            .inspector(isPresented: .constant(store.focusedCrumb != nil)) {
                if let crumb = store.focusedCrumb {
                    CrumbDetail(crumb: crumb)
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if store.isScanning {
                    ProgressView().controlSize(.small)
                }
                Button {
                    store.scan()
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .disabled(store.isScanning)
                .help("Scan again (⌘R)")
            }
        }
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { store.trash(store.selectedCrumbs) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .task {
            if store.crumbs.isEmpty || store.isStale { store.scan() }
            #if DEBUG
            if ProcessInfo.processInfo.environment["CRUMBS_DEBUG_SETTINGS"] != nil { openSettings() }
            if ProcessInfo.processInfo.environment["CRUMBS_DEBUG_FOCUS"] != nil {
                store.focused = store.visible.first { $0.verdict == .caution && $0.category == .worktree }?.id
                store.selectAllSafe()
            }
            #endif
        }
    }

    private var confirmTitle: String {
        "Move \(store.selection.count) item\(store.selection.count == 1 ? "" : "s") (\(Format.bytes(store.selectedSize))) to the Trash?"
    }

    private var confirmMessage: String {
        let cautious = store.selectedCrumbs.filter { $0.verdict == .caution }.count
        var text = "Crumbs checks each one again first and skips anything that changed. You can put items back from the Trash."
        if cautious > 0 {
            text = "\(cautious) of them are marked Check. Read their reasons first.\n\n" + text
        }
        return text
    }
}

private struct Sidebar: View {
    @Environment(CrumbStore.self) private var store

    var body: some View {
        @Bindable var store = store
        List(selection: $store.filter) {
            Section {
                row("All crumbs", icon: "square.stack.3d.up", size: store.totalSize).tag(CrumbStore.Filter.all)
            }
            Section("Kinds") {
                ForEach(CrumbCategory.allCases, id: \.self) { category in
                    let size = store.size(of: category)
                    if size > 0 {
                        row(category.label, icon: category.symbol, size: size).tag(CrumbStore.Filter.category(category))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ title: String, icon: String, size: Int64) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text(Format.bytes(size)).foregroundStyle(.secondary).monospacedDigit()
            }
        } icon: {
            Image(systemName: icon)
        }
    }
}

private struct SummaryHeader: View {
    @Environment(CrumbStore.self) private var store

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 28) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.bytes(store.size(of: .safe)))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.numericText())
                Text("safe to clear").foregroundStyle(.secondary)
            }
            stat(.caution, "to check")
            stat(.keep, "in use or unique")
            Spacer()
            status
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .animation(.default, value: store.totalSize)
    }

    private func stat(_ verdict: Verdict, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                VerdictDot(verdict: verdict)
                Text(Format.bytes(store.size(of: verdict))).font(.title3.weight(.medium)).monospacedDigit()
                    .lineLimit(1).fixedSize()
            }
            Text(caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var status: some View {
        if store.isScanning, let progress = store.progress {
            Text(progress.total > 0 ? "\(progress.phase) \(progress.completed) of \(progress.total)" : progress.phase)
                .foregroundStyle(.secondary).monospacedDigit()
        } else if let last = store.lastScan {
            Text("Scanned \(last, style: .relative) ago")
                .foregroundStyle(store.isStale ? .orange : .secondary)
                .lineLimit(1)
        }
    }
}

private struct EmptyState: View {
    @Environment(CrumbStore.self) private var store

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: CookieArt.appIcon(size: 96))
            if store.isScanning {
                Text("Looking for crumbs…").font(.title3)
                Text("Walking \(store.roots.count) folders. Big trees take a minute.").foregroundStyle(.secondary)
            } else {
                Text("No crumbs").font(.title3)
                Text("Nothing left behind in the folders Crumbs watches.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ActionBar: View {
    @Environment(CrumbStore.self) private var store
    @Binding var confirming: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let notice = store.notice {
                    Label(notice, systemImage: "checkmark.circle").foregroundStyle(.secondary).lineLimit(2)
                } else if store.isStale, !store.crumbs.isEmpty, !store.isScanning {
                    Label("These results are over an hour old. Scan again before trashing.", systemImage: "clock.arrow.circlepath")
                        .foregroundStyle(.orange)
                }
                if store.inTrashSize > 0 {
                    HStack(spacing: 8) {
                        Label("\(Format.bytes(store.inTrashSize)) from Crumbs is in the Trash. Empty the Trash to get the space back.",
                              systemImage: "trash")
                            .foregroundStyle(.primary)
                        Button("Show Trash") { store.showTrash() }
                            .buttonStyle(.link)
                    }
                }
            }
            Spacer()
            Button("Select Safe") { store.selectAllSafe() }
                .disabled(store.isScanning)
            Button {
                confirming = true
            } label: {
                if store.isTrashing {
                    ProgressView().controlSize(.small)
                } else {
                    Text(store.selection.isEmpty ? "Move to Trash" : "Move \(Format.bytes(store.selectedSize)) to Trash")
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(store.selection.isEmpty || store.isScanning || store.isTrashing || store.isStale)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

extension CrumbCategory {
    var symbol: String {
        switch self {
        case .worktree: "arrow.triangle.branch"
        case .dependencies: "shippingbox"
        case .build: "hammer"
        case .scratch: "scribble"
        case .testOutput: "checklist"
        case .cache: "internaldrive"
        }
    }
}
