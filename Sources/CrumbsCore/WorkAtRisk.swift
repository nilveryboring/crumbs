import Foundation

/// The actual work a checkout holds that exists nowhere else: which files
/// are uncommitted and which commits are on no other branch or remote.
/// "2 uncommitted files" is not enough to decide; the names are.
public struct WorkAtRisk: Sendable, Equatable {
    public struct File: Sendable, Equatable, Identifiable {
        public var id: String { path }
        public var path: String
        /// "new", "modified", "deleted", "renamed"…
        public var change: String
        public var added: Int?
        public var removed: Int?
    }

    public var files: [File] = []
    public var moreFiles = 0
    /// "abc1234 Subject line", newest first.
    public var commits: [String] = []
    public var moreCommits = 0

    public var isEmpty: Bool { files.isEmpty && commits.isEmpty }

    public static func inspect(worktree directory: String, info: WorktreeInfo, limit: Int = 12) -> WorkAtRisk {
        var risk = WorkAtRisk()
        guard !info.isOrphaned else { return risk }

        // Lines added and removed per tracked file, against the last commit.
        var counts: [String: (Int?, Int?)] = [:]
        for line in Shell.git(["diff", "HEAD", "--numstat"], in: directory).output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            if parts.count == 3 { counts[parts[2]] = (Int(parts[0]), Int(parts[1])) }
        }
        let entries = GitInspector.uncommitted(in: directory)
        for entry in entries.prefix(limit) {
            let count = counts[entry.path]
            risk.files.append(File(path: entry.path, change: label(entry.code), added: count?.0, removed: count?.1))
        }
        risk.moreFiles = max(0, entries.count - limit)

        var range: [String]?
        if info.detachedOnlyCommits > 0 {
            range = ["HEAD", "--not", "--branches", "--remotes", "--tags"]
        } else if info.unmergedCommits > 0 {
            range = ["HEAD", "--not", "--remotes"] + (info.defaultBranch.map { [$0] } ?? [])
        }
        if let range {
            let total = max(info.detachedOnlyCommits, info.unmergedCommits)
            let log = Shell.git(["log", "--format=%h %s", "-n", "\(limit)"] + range, in: directory).output
            risk.commits = log.split(separator: "\n").map(String.init)
            risk.moreCommits = max(0, total - risk.commits.count)
        }
        return risk
    }

    static func label(_ code: String) -> String {
        if code == "??" { return "new" }
        if code.contains("R") { return "renamed" }
        if code.contains("D") { return "deleted" }
        if code.contains("A") { return "added" }
        if code.contains("U") { return "conflict" }
        return "modified"
    }
}
