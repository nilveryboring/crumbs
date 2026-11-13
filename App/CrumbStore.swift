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

    /// Everything the last scan found, including crumbs of rules the user has
    /// since switched off. Views read `crumbs`.
    private var allCrumbs: [Crumb] = []
    private(set) var crumbs: [Crumb] = []
    private(set) var isScanning = false
    private(set) var progress: ScanProgress?
    @ObservationIgnored private var latestProgress: ScanProgress?
    @ObservationIgnored private var arrivals: [Crumb] = []
    @ObservationIgnored private var flushScheduled = false
    private(set) var lastScan: Date?
    private(set) var isTrashing = false
    var selection = Set<Crumb.ID>()
    var filter: Filter = .all
    var focused: Crumb.ID?
    /// Show one row per repository, with its crumbs folded underneath.
    var groupByProject: Bool = UserDefaults.standard.bool(forKey: "groupByProject") {
        didSet { UserDefaults.standard.set(groupByProject, forKey: "groupByProject") }
    }
    var notice: String?
    /// What the confirmation dialog is asking about right now.
    enum Confirmation: Equatable {
        case trash
        case delete
    }
    var confirmation: Confirmation?
    /// Free and total bytes on the disk that holds the home folder.
    private(set) var disk: (free: Int64, total: Int64)?
    /// Dead records in Codex and git that a "Tidy Up" can clear.
    private(set) var looseEnds = LooseEnds()
    private(set) var isTidying = false
    /// What Crumbs moved to the Trash that is still there. Trashing frees no
    /// space until the Trash is emptied, so the UI keeps saying so.
    private(set) var inTrash: [TrashedItem] = []
    var inTrashSize: Int64 { inTrash.reduce(0) { $0 + $1.size } }
    var roots: [String] {
        didSet { UserDefaults.standard.set(roots, forKey: "roots") }
    }
    /// The user's changes to built-in rules, keyed by rule id.
    var overrides: [String: RuleOverride] {
        didSet {
            if let data = try? JSONEncoder().encode(overrides) { UserDefaults.standard.set(data, forKey: "ruleOverrides") }
            rejudge()
        }
    }
    let builtInRules = Rule.builtIn()
    var rules: [Rule] { builtInRules.applying(overrides) }

    /// Verdicts go stale: an agent can start working in a folder any time.
    /// Past this age the app asks for a rescan before trashing anything.
    static let freshness: TimeInterval = 60 * 60

    init() {
        roots = UserDefaults.standard.stringArray(forKey: "roots") ?? CrumbScanner.defaultRoots()
        overrides = UserDefaults.standard.data(forKey: "ruleOverrides")
            .flatMap { try? JSONDecoder().decode([String: RuleOverride].self, from: $0) } ?? [:]
        #if DEBUG
        if DemoData.enabled {
            allCrumbs = DemoData.crumbs()
            lastScan = Date().addingTimeInterval(-40)
            disk = (61_300_000_000, 994_660_000_000)
            rejudge()
            if DemoData.afterTrashing {
                let safe = crumbs.filter { $0.verdict == .safe }
                let size = safe.reduce(0) { $0 + $1.size }
                allCrumbs.removeAll { crumb in safe.contains { $0.id == crumb.id } }
                rejudge()
                inTrash = [TrashedItem(trashPath: NSHomeDirectory(), size: size, date: Date())]
                notice = "Moved \(safe.count) items (\(Format.bytes(size))) to the Trash."
            }
            return
        }
        #endif
        loadCache()
        loadTrash()
        refreshDisk()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTrash(); self?.refreshDisk() }
        }
    }

    // MARK: Derived

    var visible: [Crumb] {
        switch filter {
        case .all: crumbs
        case .category(let category): crumbs.filter { $0.category == category }
        }
    }

    struct ProjectGroup: Identifiable {
        var header: Crumb
        var members: [Crumb]
        var id: String { header.id }
    }

    nonisolated static let groupRuleID = "project-group"

    /// The visible crumbs, one group per repository. The header is a made-up
    /// crumb carrying the totals so it can sit in the same table.
    var visibleGroups: [ProjectGroup] {
        Dictionary(grouping: visible, by: { $0.project ?? "" }).map { project, members in
            let safe = members.filter { $0.verdict == .safe }.reduce(0) { $0 + $1.size }
            let header = Crumb(
                path: "project:" + project, ruleID: Self.groupRuleID,
                ruleName: "\(members.count) crumb\(members.count == 1 ? "" : "s")",
                category: members[0].category, regenerable: false,
                size: members.reduce(0) { $0 + $1.size }, fileCount: members.reduce(0) { $0 + $1.fileCount },
                lastActivity: members.compactMap(\.lastActivity).max(),
                verdict: members.map(\.verdict).min() ?? .keep,
                reasons: [Reason(.safe, safe > 0 ? "\(Format.bytes(safe)) safe to clear" : "Nothing safe to clear yet")],
                title: project.isEmpty ? "Not in a repository" : (project as NSString).lastPathComponent,
                project: project.isEmpty ? nil : project)
            return ProjectGroup(header: header, members: members)
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
        #if DEBUG
        if DemoData.enabled { return }
        #endif
        isScanning = true
        notice = nil
        crumbs = []
        allCrumbs = []
        arrivals = []
        let roots = roots
        let rules = builtInRules // scan everything; overrides are applied by rejudge()
        Task {
            let result = await CrumbScanner(rules: rules).scan(roots: roots) { progress in
                Task { @MainActor [weak self] in self?.receive(progress) }
            }
            allCrumbs = result
            lastScan = Date()
            progress = nil
            isScanning = false
            rejudge() // also drops picks that are gone or no longer pickable
            saveCache()
            findLooseEnds()
        }
    }

    /// What Finder calls "available": includes space macOS can reclaim on demand.
    func refreshDisk() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity, total > 0
        else { return }
        disk = (free, Int64(total))
    }

    private func findLooseEnds() {
        refreshDisk()
        let repositories = Array(Set(allCrumbs.compactMap(\.project)))
        let roots = roots
        Task {
            looseEnds = await Task.detached(priority: .utility) {
                LooseEnds.find(repositories: repositories, roots: roots)
            }.value
        }
    }

    func tidyUp() {
        guard !isTidying, !looseEnds.isEmpty else { return }
        isTidying = true
        let ends = looseEnds
        Task {
            let left = await Task.detached(priority: .userInitiated) { ends.tidy() }.value
            let chats = ends.deadChats.count - left.deadChats.count
            let worktrees = ends.staleWorktreeCount - left.staleWorktreeCount
            var parts: [String] = []
            if chats > 0 { parts.append("\(chats) dead chat\(chats == 1 ? "" : "s") from Codex's list") }
            if worktrees > 0 { parts.append("\(worktrees) stale worktree record\(worktrees == 1 ? "" : "s")") }
            notice = parts.isEmpty ? "Couldn't tidy up: is the codex command installed?" : "Removed \(parts.joined(separator: " and "))."
            looseEnds = left
            isTidying = false
        }
    }

    /// A scan reports thousands of crumbs, the chats all at once. Showing each
    /// one as it arrives redraws the whole table every time and freezes the
    /// window, so they are collected and shown a few times a second.
    private func receive(_ progress: ScanProgress) {
        guard isScanning else { return }
        latestProgress = progress
        if let found = progress.latest { arrivals.append(found) }
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.showArrivals()
        }
    }

    private func showArrivals() {
        flushScheduled = false
        let found = arrivals
        arrivals = []
        guard isScanning else { return }
        progress = latestProgress
        guard !found.isEmpty else { return }
        var known = Set(crumbs.map(\.id))
        let fresh = found.filter { known.insert($0.id).inserted }.compactMap(judged)
        guard !fresh.isEmpty else { return }
        crumbs = (crumbs + fresh).sorted { $0.size > $1.size }
    }

    /// Stores only what differs from the built-in default, so a rule the user
    /// never touched picks up future default changes.
    func setOverride(_ ruleID: String, enabled: Bool? = nil, minIdleDays: Int? = nil) {
        guard let rule = builtInRules.first(where: { $0.id == ruleID }) else { return }
        var override = overrides[ruleID] ?? RuleOverride()
        if let enabled { override.enabled = enabled ? nil : false }
        if let minIdleDays { override.minIdleDays = minIdleDays == rule.minIdleDays ? nil : minIdleDays }
        overrides[ruleID] = override == RuleOverride() ? nil : override
    }

    /// Re-applies the current rules to what the scan found. Pure and fast: no
    /// disk access, so moving a slider updates the list instantly.
    private func rejudge() {
        guard !isScanning else { return }
        crumbs = allCrumbs.compactMap(judged)
        let present = Set(crumbs.map(\.id))
        selection = selection.filter(present.contains)
    }

    private func judged(_ crumb: Crumb) -> Crumb? {
        guard let rule = rules.first(where: { $0.id == crumb.ruleID }) else { return nil } // switched off
        var copy = crumb
        (copy.verdict, copy.reasons) = Judge.evaluate(crumb, rule: rule, now: Date())
        return copy
    }

    func selectAllSafe() {
        selection = Set(visible.filter { $0.verdict == .safe }.map(\.id))
    }

    // MARK: Trashing

    /// Re-verifies every crumb, trashes the ones that are still OK, and
    /// reports the ones that changed under us instead of trashing them.
    /// A crumb that already said Keep when the user picked it goes anyway:
    /// the dialog told them why it was marked, and they chose to.
    func trash(_ targets: [Crumb], permanently: Bool = false) {
        guard !isTrashing, !targets.isEmpty else { return }
        isTrashing = true
        let rules = rules
        let overridden = Set(targets.filter { $0.verdict == .keep }.map(\.id))
        Task {
            let (outcomes, blocked) = await Task.detached(priority: .userInitiated) {
                let scanner = CrumbScanner(rules: rules)
                let rechecked = targets.map { scanner.recheck($0) }
                let gone = rechecked.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.id)
                let blocked = rechecked.filter { $0.verdict == .keep && (!overridden.contains($0.id) || gone.contains($0.id)) }
                let ok = rechecked.filter { crumb in !blocked.contains { $0.id == crumb.id } }
                return (Trasher.trash(ok, permanently: permanently), blocked)
            }.value

            let trashed = Set(outcomes.filter { $0.error == nil }.map(\.path))
            let freed = outcomes.reduce(0) { $0 + $1.freed }
            crumbs.removeAll { trashed.contains($0.id) }
            allCrumbs.removeAll { trashed.contains($0.id) }
            for fresh in blocked {
                if let i = crumbs.firstIndex(where: { $0.id == fresh.id }) { crumbs[i] = fresh }
                if let i = allCrumbs.firstIndex(where: { $0.id == fresh.id }) { allCrumbs[i] = fresh }
            }
            selection.subtract(trashed)
            selection.subtract(blocked.map(\.id))

            let now = Date()
            inTrash += outcomes.compactMap { outcome in
                outcome.trashedTo.map { TrashedItem(trashPath: $0, size: outcome.freed, date: now) }
            }
            saveTrash()

            let count = "\(trashed.count) item\(trashed.count == 1 ? "" : "s") (\(Format.bytes(freed)))"
            var lines = [permanently ? "Deleted \(count) for good." : "Moved \(count) to the Trash."]
            if !blocked.isEmpty {
                lines.append("Skipped \(blocked.count) that changed since the scan: \(blocked.prefix(3).map(\.name).joined(separator: ", ")).")
            }
            let listed = outcomes.filter { $0.forgotten == false }.count
            if listed > 0 {
                lines.append("Codex still lists \(listed) of the chats: Crumbs couldn't run the codex command to remove them.")
            }
            let failures = outcomes.filter { $0.error != nil }
            if !failures.isEmpty {
                lines.append("Couldn't \(permanently ? "delete" : "move") \(failures.count): \(failures[0].error ?? "")")
            }
            notice = lines.joined(separator: " ")
            isTrashing = false
            saveCache()
            findLooseEnds()
        }
    }

    func showTrash() {
        if let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            NSWorkspace.shared.open(trash)
        }
    }

    /// Drops entries the user has emptied or put back.
    func refreshTrash() {
        let before = inTrash.count
        inTrash = inTrash.filter { FileManager.default.fileExists(atPath: $0.trashPath) }
        if inTrash.count != before { saveTrash() }
    }

    private func loadTrash() {
        inTrash = UserDefaults.standard.data(forKey: "inTrash")
            .flatMap { try? JSONDecoder().decode([TrashedItem].self, from: $0) } ?? []
        refreshTrash()
    }

    private func saveTrash() {
        if let data = try? JSONEncoder().encode(inTrash) { UserDefaults.standard.set(data, forKey: "inTrash") }
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
        allCrumbs = cache.crumbs
        lastScan = cache.date
        rejudge()
    }

    private func saveCache() {
        guard let lastScan else { return }
        let cache = Cache(date: lastScan, roots: roots, crumbs: allCrumbs)
        try? JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
    }
}

struct TrashedItem: Codable, Hashable {
    var trashPath: String
    var size: Int64
    var date: Date
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
