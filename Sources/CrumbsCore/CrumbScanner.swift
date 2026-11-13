import Foundation

public struct ScanProgress: Sendable {
    public var phase: String
    public var completed: Int
    public var total: Int
    /// The crumb that just finished measuring, so a UI can show results as
    /// they arrive instead of after the slowest folder.
    public var latest: Crumb?

    public init(phase: String, completed: Int, total: Int, latest: Crumb? = nil) {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.latest = latest
    }
}

public struct CrumbScanner: Sendable {
    public var rules: [Rule]
    public var maxDepth: Int
    public var concurrency: Int
    /// Where Codex keeps its chats. Nil skips them.
    public var codexHome: String?
    /// Injected so tests can pretend a fresh fixture is weeks old.
    public var now: @Sendable () -> Date

    public init(rules: [Rule] = Rule.builtIn(), maxDepth: Int = 9, concurrency: Int = max(4, ProcessInfo.processInfo.activeProcessorCount),
                codexHome: String? = CodexChats.defaultHome(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.rules = rules
        self.maxDepth = maxDepth
        self.concurrency = concurrency
        self.codexHome = codexHome
        self.now = now
    }

    public static func defaultRoots(home: String = NSHomeDirectory()) -> [String] {
        let candidates = [
            "Code", "Developer", "Projects", "projects", "src", "dev", "repos", "Documents/GitHub", "work",
            ".codex/worktrees", ".cursor/worktrees", ".claude/worktrees",
            "Library/Developer/Xcode/DerivedData",
        ].map { (home as NSString).appendingPathComponent($0) } + ["/private/tmp"]
        return candidates.filter { FileManager.default.fileExists(atPath: $0) }
    }

    struct Candidate: Sendable {
        var path: String
        var rule: Rule
        var isWorktree: Bool
    }

    public func scan(roots: [String], progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async -> [Crumb] {
        await scan(roots: roots, previous: [], memory: nil, progress: progress).crumbs
    }

    /// A scan that reads again only the folders macOS says changed since the
    /// scan `memory` came from, and carries size and file count over from
    /// `previous` for the rest. Processes, git state and verdicts are always
    /// fresh. Without a usable memory, or once a day, everything is read.
    public func scan(roots: [String], previous: [Crumb], memory: ScanMemory?, fullScanEvery: TimeInterval = 24 * 3600,
                     progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async -> (crumbs: [Crumb], memory: ScanMemory?) {
        progress(ScanProgress(phase: "Looking for crumbs", completed: 0, total: 0))
        let canonicalRoots = roots.map { canonicalPath(($0 as NSString).expandingTildeInPath) }
        let mark = ChangeJournal.mark(roots: canonicalRoots) // before reading, so changes made meanwhile count next time
        var changes: ChangeJournal.Changes?
        if let memory, !previous.isEmpty, now().timeIntervalSince(memory.fullScan) < fullScanEvery {
            changes = ChangeJournal.changes(since: memory.earlier ?? memory.mark, roots: canonicalRoots)
        }
        var unchanged: [String: Crumb] = [:]
        if let changes {
            for crumb in previous where crumb.codexSessionID == nil && !changes.touches(crumb.path) { unchanged[crumb.path] = crumb }
        }
        let known = unchanged
        // Git state is carried over too while nothing in the repository's .git has changed.
        let settled = Set(known.values.filter { crumb in
            guard let changes else { return false }
            // Rules that go by the project around them: nothing may have changed next to the folder either.
            let besides = rules.first { $0.id == crumb.ruleID }?.activity == .parent
            if besides, changes.touches((crumb.path as NSString).deletingLastPathComponent) { return false }
            if let project = crumb.project { return !changes.touches(project + "/.git") }
            return crumb.worktree == nil
        }.map(\.path))
        let fullScan = changes == nil ? now() : (memory?.fullScan ?? now())
        let newMemory = mark.map { ScanMemory(mark: $0, earlier: changes == nil ? nil : memory?.mark, fullScan: fullScan) }

        let candidates = discover(roots: roots, unchanged: known, changes: changes)
        let processes = ProcessSnapshot.capture()
        let chats = chatCrumbs()
        let total = candidates.count + chats.count
        progress(ScanProgress(phase: "Measuring", completed: 0, total: total))

        var crumbs: [Crumb] = chats
        for (index, chat) in chats.enumerated() {
            progress(ScanProgress(phase: "Measuring", completed: index + 1, total: total, latest: chat))
        }
        await withTaskGroup(of: Crumb.self) { group in
            var iterator = candidates.makeIterator()
            for _ in 0..<max(1, concurrency) {
                guard let next = iterator.next() else { break }
                group.addTask { inspect(next, processes: processes, known: known[next.path], settled: settled.contains(next.path)) }
            }
            for await crumb in group {
                crumbs.append(crumb)
                progress(ScanProgress(phase: "Measuring", completed: crumbs.count, total: total, latest: crumb))
                if let next = iterator.next() {
                    group.addTask { inspect(next, processes: processes, known: known[next.path], settled: settled.contains(next.path)) }
                }
            }
        }
        return (crumbs.sorted { $0.size > $1.size }, newMemory)
    }

    // MARK: Discovery

    /// With `changes`, a folder nothing changed under is not walked: what the
    /// last scan found there (`unchanged`) is taken as it was.
    func discover(roots: [String], unchanged: [String: Crumb] = [:], changes: ChangeJournal.Changes? = nil) -> [Candidate] {
        let globs = rules.map { rule in (rule, rule.patterns.map { Glob($0) }) }
        var found: [String: Candidate] = [:]
        var below: [String: [Crumb]] = [:] // folder → the last scan's crumbs at or under it
        if changes != nil {
            for crumb in unchanged.values {
                var path = crumb.path
                while path.count > 1 {
                    below[path, default: []].append(crumb)
                    path = (path as NSString).deletingLastPathComponent
                }
            }
        }
        var stack: [(String, Int)] = roots.map { (canonicalPath(($0 as NSString).expandingTildeInPath), 0) }
        var visited = Set<String>()

        while let (directory, depth) = stack.popLast() {
            guard visited.insert(directory).inserted else { continue }
            if let changes, !changes.touches(directory) {
                for crumb in below[directory] ?? [] {
                    guard let rule = rules.first(where: { $0.id == crumb.ruleID }) else { continue }
                    found[crumb.path] = Candidate(path: crumb.path, rule: rule, isWorktree: crumb.worktree != nil)
                }
                continue
            }
            if depth > 0, let rule = matchingRule(path: directory, globs: globs) {
                var parts: [String] = []
                if rule.splitsIntoSubfolders {
                    BulkDirectory.forEach(directory) { entry in
                        if entry.isDirectory, !Self.skippedNames.contains(entry.name) { parts.append(directory + "/" + entry.name) }
                    }
                }
                // Only loose files inside: the folder itself is the crumb.
                for path in parts.isEmpty ? [directory] : parts {
                    found[path] = Candidate(path: path, rule: rule, isWorktree: GitInspector.isLinkedWorktree(path))
                }
                continue
            }

            var children: [String] = []
            var hasGitFile = false
            BulkDirectory.forEach(directory) { entry in
                if entry.isRegularFile {
                    if !hasGitFile, entry.name == ".git" { hasGitFile = true }
                    return
                }
                guard entry.isDirectory else { return } // symlinks are never followed
                let name = entry.name
                guard !Self.skippedNames.contains(name), !Self.isBundle(name) else { return }
                children.append(name)
            }

            if depth > 0, hasGitFile, GitInspector.isLinkedWorktree(directory) {
                // A checkout is never walked into, even when its rule is switched off.
                if let fallback = rules.first(where: { $0.id == Rule.genericWorktree.id }) {
                    found[directory] = Candidate(path: directory, rule: fallback, isWorktree: true)
                }
                continue
            }
            guard depth + 1 <= maxDepth else { continue }
            for name in children { stack.append((directory + "/" + name, depth + 1)) }
        }
        return Array(found.values)
    }

    static let skippedNames: Set = [".git", ".Trash", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100"]

    static func isBundle(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return ["app", "xcodeproj", "xcworkspace", "photoslibrary", "musiclibrary", "bundle", "framework", "xcarchive"]
            .contains(String(name[name.index(after: dot)...]))
    }

    private func matchingRule(path: String, globs: [(Rule, [Glob])]) -> Rule? {
        let name = (path as NSString).lastPathComponent
        for (rule, patterns) in globs where patterns.contains(where: { $0.couldMatch(lastComponent: name) && $0.matches(path) }) {
            // Worktree rules only claim real checkouts, not the folders around them.
            if rule.category == .worktree, GitInspector.linkedGitDir(of: path) == nil { continue }
            let parent = (path as NSString).deletingLastPathComponent
            if let sibling = rule.requiresSibling,
               !FileManager.default.fileExists(atPath: (parent as NSString).appendingPathComponent(sibling)) {
                continue
            }
            if rule.requiresGitIgnored, !GitInspector.isIgnored(path) { continue }
            return rule
        }
        return nil
    }

    // MARK: Inspection

    /// `known` is the same folder from the last scan, when nothing inside it
    /// has changed since: its files are not read again.
    /// `settled`: nothing in its repository's git data changed either, so git is not asked again.
    func inspect(_ candidate: Candidate, processes: ProcessSnapshot, known: Crumb? = nil, settled: Bool = false) -> Crumb {
        let rule = candidate.rule
        if settled, var crumb = known, crumb.ruleID == rule.id, crumb.folderID == Self.folderID(of: candidate.path) {
            crumb.processes = processes.processes(inside: candidate.path)
            (crumb.verdict, crumb.reasons) = Judge.evaluate(crumb, rule: rule, now: now())
            return crumb
        }
        let stats: DirectoryStats
        let folderID = Self.folderID(of: candidate.path)
        if let known, known.ruleID == rule.id, let folderID, known.folderID == folderID {
            stats = DirectoryStats(size: known.size, fileCount: known.fileCount,
                                   newestModification: rule.activity == .self ? known.lastActivity : nil, secrets: known.secrets)
        } else {
            stats = SizeInspector.stats(of: candidate.path, lookForSecrets: !rule.regenerable)
        }
        let worktree = candidate.isWorktree ? GitInspector.inspectWorktree(at: candidate.path) : nil
        var secrets = stats.secrets
        if worktree != nil {
            secrets = GitInspector.secretsOnlyHere(secrets, worktree: candidate.path)
        }

        var activity: Date?
        switch candidate.rule.activity {
        case .self:
            activity = [stats.newestModification, worktree?.lastCommit].compactMap { $0 }.max()
        case .parent:
            let parent = (candidate.path as NSString).deletingLastPathComponent
            activity = [SizeInspector.shallowNewestModification(of: parent), GitInspector.lastCommitDate(containing: parent)]
                .compactMap { $0 }.max()
        }

        var crumb = Crumb(
            path: candidate.path,
            ruleID: candidate.rule.id,
            ruleName: candidate.rule.name,
            category: candidate.rule.category,
            regenerable: candidate.rule.regenerable,
            emptyParentPattern: candidate.rule.emptyParentPattern,
            size: stats.size,
            fileCount: stats.fileCount,
            lastActivity: activity,
            worktree: worktree,
            secrets: secrets,
            processes: processes.processes(inside: candidate.path),
            verdict: .safe,
            reasons: [],
            project: GitInspector.project(of: candidate.path)
        )
        crumb.folderID = folderID
        (crumb.verdict, crumb.reasons) = Judge.evaluate(crumb, rule: candidate.rule, now: now())
        return crumb
    }

    static func folderID(of path: String) -> UInt64? {
        var info = stat()
        return lstat(path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    // MARK: Chats

    func chatCrumbs() -> [Crumb] {
        let chatRules = Dictionary(uniqueKeysWithValues: rules.filter { $0.category == .chat }.map { ($0.id, $0) })
        guard let codexHome, !chatRules.isEmpty else { return [] }
        return CodexChats.find(home: codexHome, ruleIDs: Set(chatRules.keys)).compactMap { chat in
            guard let rule = chatRules[chat.ruleID] else { return nil }
            let stats = CodexChats.stats(of: chat.path)
            var crumb = Crumb(path: chat.path, ruleID: rule.id, ruleName: rule.name, category: rule.category,
                              regenerable: rule.regenerable, size: stats.size, fileCount: 1,
                              lastActivity: stats.modified, title: chat.title, codexSessionID: chat.sessionID)
            (crumb.verdict, crumb.reasons) = Judge.evaluate(crumb, rule: rule, now: now())
            return crumb
        }
    }

    // MARK: Recheck

    /// Fast re-verification right before trashing: fresh process and git
    /// state, size and activity carried over from the scan. Anything that
    /// got worse since the scan shows up in the new verdict.
    public func recheck(_ crumb: Crumb) -> Crumb {
        var fresh = crumb
        guard FileManager.default.fileExists(atPath: crumb.path) else {
            fresh.verdict = .keep
            fresh.reasons = [Reason(.keep, "No longer exists")]
            return fresh
        }
        let rule = rules.first { $0.id == crumb.ruleID } ?? Rule.builtIn().first { $0.id == crumb.ruleID } ?? .genericWorktree
        fresh.processes = ProcessSnapshot.capture().processes(inside: crumb.path)
        if crumb.worktree != nil {
            fresh.worktree = GitInspector.inspectWorktree(at: crumb.path)
        }
        if crumb.codexSessionID != nil { // a chat picked up again since the scan
            fresh.lastActivity = CodexChats.stats(of: crumb.path).modified
        }
        (fresh.verdict, fresh.reasons) = Judge.evaluate(fresh, rule: rule, now: now())
        return fresh
    }
}
