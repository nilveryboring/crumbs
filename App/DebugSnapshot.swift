#if DEBUG
import AppKit

/// `CRUMBS_SNAPSHOT_DIR=/some/dir` makes a debug build write PNGs of its own
/// windows every few seconds. Lets UI checks run without screen-recording
/// permission.
enum DebugSnapshot {
    @MainActor static func startIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["CRUMBS_SNAPSHOT_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Screenshots want the key-window look: colored traffic lights, prominent buttons.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSApp.activate(ignoringOtherApps: true)
            if let size = ProcessInfo.processInfo.environment["CRUMBS_DEBUG_SIZE"]?.split(separator: "x"),
               size.count == 2, let w = Double(size[0]), let h = Double(size[1]),
               let main = NSApp.windows.first(where: { $0.title == "Crumbs" }) {
                main.setContentSize(NSSize(width: w, height: h))
                main.makeKeyAndOrderFront(nil)
            }
        }
        var tick = 0
        Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            MainActor.assumeIsolated {
                tick += 1
                for (index, window) in NSApp.windows.enumerated() where window.isVisible {
                    guard let view = window.contentView?.superview ?? window.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                    else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let name = window.title.isEmpty ? "window\(index)" : window.title
                    let data = rep.representation(using: .png, properties: [:])
                    try? data?.write(to: URL(fileURLWithPath: "\(dir)/\(name)-latest.png"))
                }
            }
        }
    }
}
#endif
