import Foundation

enum GitInspector {
    /// The `gitdir:` a linked worktree's `.git` file points at, or nil when
    /// `.git` is missing or a real directory (a main checkout).
    static func linkedGitDir(of directory: String) -> String? {
        let dotGit = (directory as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir), !isDir.boolValue,
              let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
        else { return nil }
        var gitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitDir.hasPrefix("/") {
            gitDir = ((directory as NSString).appendingPathComponent(gitDir) as NSString).standardizingPath
        }
        return gitDir
    }

    /// Worktrees point into `<repo>/.git/worktrees/<name>`; submodules point
    /// into `.git/modules/` and are not ours to touch.
    static func isLinkedWorktree(_ directory: String) -> Bool {
        guard let gitDir = linkedGitDir(of: directory) else { return false }
        return gitDir.contains("/worktrees/")
    }

    static func inspectWorktree(at directory: String) -> WorktreeInfo {
        guard let gitDir = linkedGitDir(of: directory) else { return WorktreeInfo(isOrphaned: true) }
        let commonDir = gitDir.components(separatedBy: "/worktrees/").first
        guard FileManager.default.fileExists(atPath: gitDir),
              Shell.git(["rev-parse", "--git-dir"], in: directory).status == 0
        else {
            return WorktreeInfo(commonDir: commonDir.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil },
                                isOrphaned: true)
        }

        var info = WorktreeInfo(commonDir: commonDir)
        let branch = Shell.git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: directory)
        info.branch = branch.status == 0 && !branch.output.isEmpty ? branch.output : nil

        let status = Shell.git(["status", "--porcelain", "--untracked-files=normal"], in: directory)
        info.dirtyFiles = status.output.isEmpty ? 0 : status.output.split(separator: "\n").count

        if let seconds = TimeInterval(Shell.git(["log", "-1", "--format=%ct"], in: directory).output) {
            info.lastCommit = Date(timeIntervalSince1970: seconds)
        }

        let defaultBranch = Self.defaultBranch(in: directory)
        info.defaultBranch = defaultBranch
        var exclusions = ["--remotes"]
        if let defaultBranch { exclusions.append(defaultBranch) }
        let unmerged = Int(Shell.git(["rev-list", "--count", "HEAD", "--not"] + exclusions, in: directory).output) ?? 0

        if info.branch == nil {
            // Detached: anything not reachable from another ref is lost with the checkout.
            let orphaned = Shell.git(["rev-list", "--count", "HEAD", "--not", "--branches", "--remotes", "--tags"], in: directory)
            info.detachedOnlyCommits = Int(orphaned.output) ?? 0
        } else {
            info.unmergedCommits = unmerged
        }
        return info
    }

    /// Drops secret-looking files that don't make a worktree unique: tracked
    /// files (git has them) and byte-identical copies of the main checkout's.
    static func secretsOnlyHere(_ files: [String], worktree: String) -> [String] {
        guard !files.isEmpty else { return files }
        let listed = Shell.git(["--literal-pathspecs", "ls-files", "-z", "--"] + files, in: worktree)
        let tracked = listed.status == 0 ? Set(listed.output.split(separator: "\0").map(String.init)) : []
        let main = mainCheckout(of: worktree)
        return files.filter { file in
            if tracked.contains(file) { return false }
            if let main, FileManager.default.contentsEqual(atPath: worktree + "/" + file, andPath: main + "/" + file) {
                return false
            }
            return true
        }
    }

    /// The repository's primary checkout, derived from the worktree's gitdir
    /// even when that gitdir itself is gone.
    static func mainCheckout(of worktree: String) -> String? {
        guard let gitDir = linkedGitDir(of: worktree),
              let common = gitDir.components(separatedBy: "/worktrees/").first, common.hasSuffix("/.git")
        else { return nil }
        let main = String(common.dropLast("/.git".count))
        return FileManager.default.fileExists(atPath: main) ? main : nil
    }

    static func defaultBranch(in directory: String) -> String? {
        let remoteHead = Shell.git(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: directory)
        if remoteHead.status == 0, !remoteHead.output.isEmpty { return remoteHead.output }
        for name in ["main", "master", "trunk"] where
            Shell.git(["show-ref", "--verify", "--quiet", "refs/heads/\(name)"], in: directory).status == 0 {
            return name
        }
        return nil
    }

    static func isIgnored(_ directory: String) -> Bool {
        let parent = (directory as NSString).deletingLastPathComponent
        let name = (directory as NSString).lastPathComponent
        return Shell.git(["check-ignore", "-q", "--", name], in: parent).status == 0
    }

    static func lastCommitDate(containing directory: String) -> Date? {
        let result = Shell.git(["log", "-1", "--format=%ct"], in: directory)
        guard result.status == 0, let seconds = TimeInterval(result.output) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func pruneWorktrees(commonDir: String) {
        _ = Shell.run(Shell.git, ["--git-dir=\(commonDir)", "worktree", "prune"])
    }
}
