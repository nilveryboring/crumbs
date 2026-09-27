import AppKit
import CrumbsCore
import Foundation
import Observation

@Observable @MainActor
final class CrumbStore {
    enum Filter: Hashable {
        case all
        case category(CrumbCategory)
    }

    private(set) var crumbs: [Crumb] = []
    private(set) var isScanning = false
    private(set) var progress: ScanProgress?
    private(set) var lastScan: Date?
    private(set) var isTrashing = false
    var selection = Set<Crumb.ID>()
    var filter: Filter = .all
    var focused: Crumb.ID?
    var notice: String?
    var roots: [String] {
        didSet { UserDefaults.standard.set(roots, forKey: "roots") }
    }

    /// Verdicts go stale: an agent can start working in a folder any time.
    /// Past this age the app asks for a rescan before trashing anything.
    static let freshness: TimeInterval = 60 * 60

    init() {
        roots = UserDefaults.standard.stringArray(forKey: "roots") ?? CrumbScanner.defaultRoots()
        loadCache()
    }

    // MARK: Derived

    var visible: [Crumb] {
        switch filter {
        case .all: crumbs
        case .category(let category): crumbs.filter { $0.category == category }
        }
    }

    var selectedCrumbs: [Crumb] { crumbs.filter { selection.contains($0.id) } }
    var selectedSize: Int64 { selectedCrumbs.reduce(0) { $0 + $1.size } }
    func size(of verdict: Verdict) -> Int64 { crumbs.filter { $0.verdict == verdict }.reduce(0) { $0 + $1.size } }
    func size(of category: CrumbCategory) -> Int64 { crumbs.filter { $0.category == category }.reduce(0) { $0 + $1.size } }
    var totalSize: Int64 { crumbs.reduce(0) { $0 + $1.size } }
    var isStale: Bool { lastScan.map { Date().timeIntervalSince($0) > Self.freshness } ?? true }
    var focusedCrumb: Crumb? { focused.flatMap { id in crumbs.first { $0.id == id } } }

    // MARK: Scanning

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        notice = nil
        crumbs = []
        let roots = roots
        Task {
            let result = await CrumbScanner().scan(roots: roots) { progress in
                Task { @MainActor [weak self] in self?.receive(progress) }
            }
            crumbs = result
            // Keep what the user picked if it is still there and still safe to pick.
            selection = selection.filter { id in result.contains { $0.id == id && $0.verdict != .keep } }
            lastScan = Date()
            progress = nil
            isScanning = false
            saveCache()
        }
    }

    private func receive(_ progress: ScanProgress) {
        guard isScanning else { return }
        self.progress = progress
        if let crumb = progress.latest, !crumbs.contains(where: { $0.id == crumb.id }) {
            let index = crumbs.firstIndex { $0.size < crumb.size } ?? crumbs.endIndex
            crumbs.insert(crumb, at: index)
        }
    }

    func selectAllSafe() {
        selection = Set(visible.filter { $0.verdict == .safe }.map(\.id))
    }

    // MARK: Trashing

    /// Re-verifies every crumb, trashes the ones that are still OK, and
    /// reports the ones that changed under us instead of trashing them.
    func trash(_ targets: [Crumb]) {
        guard !isTrashing, !targets.isEmpty else { return }
        isTrashing = true
        Task {
            let (outcomes, blocked) = await Task.detached(priority: .userInitiated) {
                let scanner = CrumbScanner()
                let rechecked = targets.map { scanner.recheck($0) }
                let blocked = rechecked.filter { $0.verdict == .keep }
                let ok = rechecked.filter { $0.verdict != .keep }
                return (Trasher.trash(ok), blocked)
            }.value

            let trashed = Set(outcomes.filter { $0.error == nil }.map(\.path))
            let freed = outcomes.reduce(0) { $0 + $1.freed }
            crumbs.removeAll { trashed.contains($0.id) }
            for fresh in blocked {
                if let i = crumbs.firstIndex(where: { $0.id == fresh.id }) { crumbs[i] = fresh }
            }
            selection.subtract(trashed)
            selection.subtract(blocked.map(\.id))

            var lines = ["Moved \(trashed.count) to the Trash, \(Format.bytes(freed)) freed."]
            if !blocked.isEmpty {
                lines.append("Skipped \(blocked.count) that changed since the scan: \(blocked.prefix(3).map(\.name).joined(separator: ", ")).")
            }
            let failures = outcomes.filter { $0.error != nil }
            if !failures.isEmpty {
                lines.append("Couldn't move \(failures.count): \(failures[0].error ?? "")")
            }
            notice = lines.joined(separator: " ")
            isTrashing = false
            saveCache()
        }
    }

    func reveal(_ crumb: Crumb) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: crumb.path)])
    }

    // MARK: Cache

    private struct Cache: Codable {
        var date: Date
        var roots: [String]
        var crumbs: [Crumb]
    }

    private var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Crumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("last-scan.json")
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.roots == roots
        else { return }
        crumbs = cache.crumbs
        lastScan = cache.date
    }

    private func saveCache() {
        guard let lastScan else { return }
        let cache = Cache(date: lastScan, roots: roots, crumbs: crumbs)
        try? JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: n)
    }

    static func path(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func age(_ date: Date?) -> String {
        guard let date else { return "—" }
        let days = Int(Date().timeIntervalSince(date) / 86_400)
        switch days {
        case ..<1: return "today"
        case 1: return "1 day"
        case ..<60: return "\(days) days"
        default: return "\(days / 30) months"
        }
    }
}
