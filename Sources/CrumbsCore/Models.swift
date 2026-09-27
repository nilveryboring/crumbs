import Foundation

/// How safe it is to throw a crumb away. Ordered: the worst reason wins.
public enum Verdict: Int, Codable, Sendable, Comparable, CaseIterable {
    case safe
    case caution
    case keep

    public static func < (lhs: Verdict, rhs: Verdict) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .safe: "Safe"
        case .caution: "Check"
        case .keep: "Keep"
        }
    }
}

public enum CrumbCategory: String, Codable, Sendable, CaseIterable {
    case worktree
    case dependencies
    case build
    case scratch
    case testOutput
    case cache

    public var label: String {
        switch self {
        case .worktree: "Worktrees"
        case .dependencies: "Dependencies"
        case .build: "Build output"
        case .scratch: "Scratch"
        case .testOutput: "Test output"
        case .cache: "Caches"
        }
    }
}

/// One line of evidence behind a verdict. `.safe` reasons are informational.
public struct Reason: Codable, Sendable, Hashable {
    public var level: Verdict
    public var text: String

    public init(_ level: Verdict, _ text: String) {
        self.level = level
        self.text = text
    }
}

public struct WorktreeInfo: Codable, Sendable, Hashable {
    /// Path of the owning repository's git dir (`<repo>/.git`), when it still exists.
    public var commonDir: String?
    public var branch: String?
    public var isOrphaned: Bool
    public var dirtyFiles: Int
    /// Commits on this branch that are on no remote and not in the default branch.
    public var unmergedCommits: Int
    /// Commits reachable only from a detached HEAD. These die with the checkout.
    public var detachedOnlyCommits: Int
    public var defaultBranch: String?
    public var lastCommit: Date?

    public init(commonDir: String? = nil, branch: String? = nil, isOrphaned: Bool = false,
                dirtyFiles: Int = 0, unmergedCommits: Int = 0, detachedOnlyCommits: Int = 0,
                defaultBranch: String? = nil, lastCommit: Date? = nil) {
        self.commonDir = commonDir
        self.branch = branch
        self.isOrphaned = isOrphaned
        self.dirtyFiles = dirtyFiles
        self.unmergedCommits = unmergedCommits
        self.detachedOnlyCommits = detachedOnlyCommits
        self.defaultBranch = defaultBranch
        self.lastCommit = lastCommit
    }
}

public struct ProcessRef: Codable, Sendable, Hashable {
    public var pid: Int32
    public var name: String
}

public struct Crumb: Identifiable, Codable, Sendable, Hashable {
    public var id: String { path }
    public var path: String
    public var ruleID: String
    public var ruleName: String
    public var category: CrumbCategory
    public var regenerable: Bool
    public var emptyParentPattern: String?
    public var size: Int64
    public var fileCount: Int
    public var lastActivity: Date?
    public var worktree: WorktreeInfo?
    public var secrets: [String]
    public var processes: [ProcessRef]
    public var verdict: Verdict
    public var reasons: [Reason]

    public var name: String { (path as NSString).lastPathComponent }
}
