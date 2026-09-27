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
    /// Injected so tests can pretend a fresh fixture is weeks old.
    public var now: @Sendable () -> Date

    public init(rules: [Rule] = Rule.builtIn(), maxDepth: Int = 9, concurrency: Int = max(4, ProcessInfo.processInfo.activeProcessorCount),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.rules = rules
        self.maxDepth = maxDepth
        self.concurrency = concurrency
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
        progress(ScanProgress(phase: "Looking for crumbs", completed: 0, total: 0))
        let candidates = discover(roots: roots)
        let processes = ProcessSnapshot.capture()
        let total = candidates.count
        progress(ScanProgress(phase: "Measuring", completed: 0, total: total))

        var crumbs: [Crumb] = []
        await withTaskGroup(of: Crumb.self) { group in
            var iterator = candidates.makeIterator()
            for _ in 0..<max(1, concurrency) {
                guard let next = iterator.next() else { break }
                group.addTask { inspect(next, processes: processes) }
            }
            for await crumb in group {
                crumbs.append(crumb)
                progress(ScanProgress(phase: "Measuring", completed: crumbs.count, total: total, latest: crumb))
                if let next = iterator.next() {
                    group.addTask { inspect(next, processes: processes) }
                }
            }
        }
        return crumbs.sorted { $0.size > $1.size }
    }

    // MARK: Discovery

    func discover(roots: [String]) -> [Candidate] {
        let globs = rules.map { rule in (rule, rule.patterns.map { Glob($0) }) }
        var found: [String: Candidate] = [:]
        var stack: [(String, Int)] = roots.map { (canonicalPath(($0 as NSString).expandingTildeInPath), 0) }
        var visited = Set<String>()

        while let (directory, depth) = stack.popLast() {
            guard visited.insert(directory).inserted else { continue }
            if depth > 0, let rule = matchingRule(path: directory, globs: globs) {
                found[directory] = Candidate(path: directory, rule: rule, isWorktree: GitInspector.isLinkedWorktree(directory))
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

    func inspect(_ candidate: Candidate, processes: ProcessSnapshot) -> Crumb {
        let rule = candidate.rule
        let stats = SizeInspector.stats(of: candidate.path, lookForSecrets: !rule.regenerable)
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
            reasons: []
        )
        (crumb.verdict, crumb.reasons) = Judge.evaluate(crumb, rule: candidate.rule, now: now())
        return crumb
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
        (fresh.verdict, fresh.reasons) = Judge.evaluate(fresh, rule: rule, now: now())
        return fresh
    }
}
