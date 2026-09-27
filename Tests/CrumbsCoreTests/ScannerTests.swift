@testable import CrumbsCore
import Foundation
import Testing

/// End-to-end against real git repos in a temp folder. `now` is pushed a
/// month ahead so freshly made fixtures read as idle.
@Suite(.serialized) struct ScannerTests {
    let root: String
    let later: @Sendable () -> Date = { Date().addingTimeInterval(40 * 86_400) }

    init() throws {
        root = canonicalPath(NSTemporaryDirectory()) + "/crumbs-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func git(_ args: [String], in dir: String) -> String {
        let r = Shell.run(Shell.git, ["-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"] + args)
        return r.output
    }

    func write(_ path: String, _ text: String = "x") throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func makeRepo() throws -> String {
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        git(["init", "-q"], in: repo)
        try write(repo + "/README.md", "hi")
        try write(repo + "/.gitignore", "dist/\ntmp/\n.claude/\n")
        git(["add", "."], in: repo)
        git(["commit", "-qm", "init"], in: repo)
        return repo
    }

    func scan() async -> [String: Crumb] {
        let crumbs = await CrumbScanner(now: later).scan(roots: [root])
        return Dictionary(uniqueKeysWithValues: crumbs.map { ($0.path, $0) })
    }

    @Test func cleanMergedWorktreeIsSafe() async throws {
        let repo = try makeRepo()
        let wt = repo + "/.claude/worktrees/agent-1"
        git(["worktree", "add", "-q", "-b", "agent-1", wt], in: repo)

        let crumb = try #require(await scan()[wt])
        #expect(crumb.ruleID == "claude-code-worktree")
        #expect(crumb.worktree?.branch == "agent-1")
        #expect(crumb.worktree?.dirtyFiles == 0)
        #expect(crumb.verdict == .safe)
    }

    @Test func dirtyWorktreeIsKept() async throws {
        let repo = try makeRepo()
        let wt = repo + "/.claude/worktrees/agent-2"
        git(["worktree", "add", "-q", "-b", "agent-2", wt], in: repo)
        try write(wt + "/new-idea.swift")

        let crumb = try #require(await scan()[wt])
        #expect(crumb.worktree?.dirtyFiles == 1)
        #expect(crumb.verdict == .keep)
    }

    @Test func unmergedBranchIsInformationalOnly() async throws {
        let repo = try makeRepo()
        let wt = repo + "/.claude/worktrees/agent-3"
        git(["worktree", "add", "-q", "-b", "agent-3", wt], in: repo)
        try write(wt + "/feature.txt")
        git(["add", "."], in: wt)
        git(["commit", "-qm", "feature"], in: wt)

        let crumb = try #require(await scan()[wt])
        #expect(crumb.worktree?.unmergedCommits == 1)
        #expect(crumb.verdict == .safe) // the branch survives in the repo
    }

    @Test func detachedCommitsAreKept() async throws {
        let repo = try makeRepo()
        let wt = root + "/detached"
        git(["worktree", "add", "-q", "--detach", wt], in: repo)
        try write(wt + "/only-here.txt")
        git(["add", "."], in: wt)
        git(["commit", "-qm", "orphan"], in: wt)

        let crumb = try #require(await scan()[wt])
        #expect(crumb.ruleID == "git-worktree")
        #expect(crumb.worktree?.detachedOnlyCommits == 1)
        #expect(crumb.verdict == .keep)
    }

    @Test func orphanedWorktreeNeedsACheck() async throws {
        let repo = try makeRepo()
        let wt = repo + "/.claude/worktrees/agent-4"
        git(["worktree", "add", "-q", "-b", "agent-4", wt], in: repo)
        try FileManager.default.removeItem(atPath: repo + "/.git/worktrees/agent-4")

        let crumb = try #require(await scan()[wt])
        #expect(crumb.worktree?.isOrphaned == true)
        #expect(crumb.verdict == .caution)
    }

    @Test func runningProcessKeepsIt() async throws {
        let repo = try makeRepo()
        let wt = repo + "/.claude/worktrees/agent-5"
        git(["worktree", "add", "-q", "-b", "agent-5", wt], in: repo)
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        sleeper.currentDirectoryURL = URL(fileURLWithPath: wt + "/")
        try sleeper.run()
        defer { sleeper.terminate() }

        let crumb = try #require(await scan()[wt])
        #expect(crumb.processes.contains { $0.pid == sleeper.processIdentifier })
        #expect(crumb.verdict == .keep)
    }

    @Test func secretsNeedACheck() async throws {
        let repo = try makeRepo()
        try write(repo + "/tmp/realtime-production-secrets.json", "{}")

        let crumb = try #require(await scan()[repo + "/tmp"])
        #expect(crumb.ruleID == "scratch-tmp")
        #expect(crumb.secrets == ["realtime-production-secrets.json"])
        #expect(crumb.verdict == .caution)
    }

    @Test func copiedEnvFileIsNotASecretOfTheWorktree() async throws {
        let repo = try makeRepo()
        try write(repo + "/.env.local", "KEY=1")
        let copy = repo + "/.claude/worktrees/copy"
        let changed = repo + "/.claude/worktrees/changed"
        git(["worktree", "add", "-q", "-b", "copy", copy], in: repo)
        git(["worktree", "add", "-q", "-b", "changed", changed], in: repo)
        try write(copy + "/.env.local", "KEY=1")
        try write(changed + "/.env.local", "KEY=2")

        let crumbs = await scan()
        #expect(crumbs[copy]?.secrets == [])
        #expect(crumbs[changed]?.secrets == [".env.local"])
    }

    @Test func hardLinksOutsideTheFolderFreeNothing() async throws {
        let repo = try makeRepo()
        let store = root + "/store/blob"
        try write(store, String(repeating: "x", count: 100_000))
        try FileManager.default.createDirectory(atPath: repo + "/node_modules/pkg", withIntermediateDirectories: true)
        try FileManager.default.linkItem(atPath: store, toPath: repo + "/node_modules/pkg/blob")
        try write(repo + "/node_modules/pkg/own.js", String(repeating: "y", count: 100_000))

        let crumb = try #require(await scan()[repo + "/node_modules"])
        #expect(crumb.fileCount == 2)
        #expect(crumb.size > 90_000 && crumb.size < 150_000) // own.js only
    }

    @Test func codexWrapperFolderIsTrashedWhenEmpty() async throws {
        let repo = try makeRepo()
        let wrapper = root + "/codex/worktrees/2263"
        let wt = wrapper + "/repo"
        git(["worktree", "add", "-q", "-b", "codex-task", wt], in: repo)
        var crumb = try #require(await scan()[wt])
        crumb.emptyParentPattern = root + "/codex/worktrees/*"

        _ = Trasher.trash([crumb])
        #expect(!FileManager.default.fileExists(atPath: wrapper))
        #expect(FileManager.default.fileExists(atPath: root + "/codex/worktrees"))
    }

    @Test func buildOutputOnlyWhenIgnored() async throws {
        let repo = try makeRepo()
        try write(repo + "/dist/app.js")
        try write(root + "/loose/dist/app.js") // not in a repo: could be anything

        let crumbs = await scan()
        #expect(crumbs[repo + "/dist"]?.ruleID == "js-build-output")
        #expect(crumbs[root + "/loose/dist"] == nil)
    }

    @Test func freshCrumbsAreKept() async throws {
        let repo = try makeRepo()
        try write(repo + "/node_modules/pkg/index.js")
        let crumbs = await CrumbScanner().scan(roots: [root]) // real clock
        #expect(crumbs.first { $0.path == repo + "/node_modules" }?.verdict == .keep)
    }

    @Test func trashMovesWorktreeAndPrunes() async throws {
        let repo = try makeRepo()
        let wt = repo + "/.claude/worktrees/agent-6"
        git(["worktree", "add", "-q", "-b", "agent-6", wt], in: repo)
        let crumb = try #require(await scan()[wt])

        let outcome = try #require(Trasher.trash([crumb]).first)
        #expect(outcome.error == nil)
        #expect(!FileManager.default.fileExists(atPath: wt))
        #expect(!git(["worktree", "list"], in: repo).contains("agent-6"))
        #expect(git(["branch", "--list", "agent-6"], in: repo).contains("agent-6"))
        if let trashed = outcome.trashedTo { try? FileManager.default.removeItem(atPath: trashed) }
    }
}
