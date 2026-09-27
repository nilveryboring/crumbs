import CrumbsCore
import SwiftUI

struct MenuBarView: View {
    @Environment(CrumbStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: CookieArt.appIcon(size: 36))
                VStack(alignment: .leading, spacing: 1) {
                    Text(Format.bytes(store.size(of: .safe)))
                        .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("safe to clear").foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach([CrumbCategory.worktree, .dependencies, .build, .cache, .scratch, .testOutput], id: \.self) { category in
                    let size = store.crumbs.filter { $0.category == category && $0.verdict == .safe }.reduce(0) { $0 + $1.size }
                    if size > 0 {
                        HStack {
                            Label(category.label, systemImage: category.symbol)
                            Spacer()
                            Text(Format.bytes(size)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if store.inTrashSize > 0 {
                Button {
                    store.showTrash()
                } label: {
                    Label("\(Format.bytes(store.inTrashSize)) waiting in the Trash. Empty it to free the space.", systemImage: "trash")
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.link)
            }

            Divider()
            Group {
                if store.isScanning, let progress = store.progress {
                    Text("\(progress.phase)… \(progress.completed)/\(max(progress.total, 1))")
                } else if let last = store.lastScan {
                    Text("Scanned \(last, style: .relative) ago")
                } else {
                    Text("Not scanned yet")
                }
            }
            .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button("Open Crumbs") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.borderedProminent)
                Button("Scan") { store.scan() }.disabled(store.isScanning)
                Spacer()
                Link("Feedback", destination: Links.feedback)
                    .font(.callout)
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}
