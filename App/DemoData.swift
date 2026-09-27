#if DEBUG
import CrumbsCore
import Foundation

/// `CRUMBS_DEMO=1` swaps the real scan for this made-up disk, for screenshots
/// that don't show anyone's actual projects. Verdicts still come from Judge.
enum DemoData {
    static var enabled: Bool { ProcessInfo.processInfo.environment["CRUMBS_DEMO"] != nil }
    /// `CRUMBS_DEMO=trashed`: the moment after "Move to Trash".
    static var afterTrashing: Bool { ProcessInfo.processInfo.environment["CRUMBS_DEMO"] == "trashed" }

    static func crumbs() -> [Crumb] {
        let rules = Dictionary(uniqueKeysWithValues: Rule.builtIn().map { ($0.id, $0) })
        let home = NSHomeDirectory()
        func days(_ n: Double) -> Date { Date().addingTimeInterval(-n * 86_400) }
        func gb(_ n: Double) -> Int64 { Int64(n * 1_000_000_000) }
        func crumb(_ path: String, _ ruleID: String, _ size: Int64, _ idle: Double, files: Int = 40_000,
                   worktree: WorktreeInfo? = nil, secrets: [String] = [], processes: [ProcessRef] = []) -> Crumb {
            let rule = rules[ruleID]!
            return Crumb(path: path.hasPrefix("/") ? path : home + "/" + path, ruleID: rule.id, ruleName: rule.name,
                         category: rule.category, regenerable: rule.regenerable, size: size, fileCount: files,
                         lastActivity: days(idle), worktree: worktree, secrets: secrets, processes: processes)
        }
        func clean(_ branch: String, unmerged: Int = 0) -> WorktreeInfo {
            WorktreeInfo(commonDir: "", branch: branch, unmergedCommits: unmerged, defaultBranch: "origin/main")
        }

        return [
            crumb("Library/Developer/Xcode/DerivedData/Pocket-fjdkslqweruiobnm", "xcode-derived-data", gb(6.02), 412),
            crumb("/private/tmp/storefront-release-0914", "git-worktree", gb(5.31), 11,
                  worktree: WorktreeInfo(isOrphaned: true)),
            crumb("Code/marketing-site/.next", "js-build-output", gb(4.07), 19),
            crumb("Code/storefront/.claude/worktrees/agent-a4c2dd35", "claude-code-worktree", gb(3.41), 21,
                  worktree: clean("worktree-agent-a4c2dd35")),
            crumb("Code/storefront/.claude/worktrees/agent-b81f02c9", "claude-code-worktree", gb(3.22), 18,
                  worktree: clean("agent/checkout-copy", unmerged: 2)),
            crumb("Code/storefront/.claude/worktrees/fix-checkout-race", "claude-code-worktree", gb(3.18), 6,
                  worktree: WorktreeInfo(commonDir: "", branch: "fix-checkout-race", dirtyFiles: 2, defaultBranch: "origin/main")),
            crumb("Code/cli-tool/target", "rust-target", gb(3.05), 33),
            crumb("Code/dashboard/.claude/worktrees/agent-c19d77e0", "claude-code-worktree", gb(2.91), 1.6,
                  worktree: clean("agent/chart-tooltips")),
            crumb("Code/storefront/node_modules", "node-modules", gb(2.44), 0.08, files: 180_000),
            crumb(".codex/worktrees/7f3a/api-server", "codex-worktree", gb(2.21), 12,
                  worktree: clean("codex/rate-limits"), secrets: [".env.local"]),
            crumb(".codex/worktrees/onboarding-copy", "codex-worktree", gb(2.02), 9,
                  worktree: clean("codex/onboarding-copy")),
            crumb("Code/dashboard/node_modules", "node-modules", gb(1.93), 46, files: 150_000),
            crumb("Code/storefront/tmp", "scratch-tmp", gb(1.18), 0.02,
                  processes: [ProcessRef(pid: 48213, name: "node")]),
            crumb("Code/api-server/.venv", "python-venv", 850_000_000, 61),
            crumb("Code/storefront/test-results", "test-output", 184_000_000, 9, files: 2_300),
        ]
    }
}
#endif
