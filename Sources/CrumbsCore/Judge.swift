import Foundation

/// Turns evidence into a verdict. Every rule that can block a delete lives
/// here, so this file is the one to read when a verdict looks wrong.
public enum Judge {
    public static func evaluate(_ crumb: Crumb, rule: Rule, now: Date) -> (Verdict, [Reason]) {
        var reasons: [Reason] = []

        if !crumb.processes.isEmpty {
            let names = crumb.processes.prefix(3).map { "\($0.name) (\($0.pid))" }.joined(separator: ", ")
            reasons.append(Reason(.keep, "In use right now by \(names)"))
        }

        if let wt = crumb.worktree {
            if wt.isOrphaned {
                reasons.append(Reason(.caution, "Orphaned worktree: its repository metadata is gone, so Crumbs can't check it for uncommitted work"))
            }
            if wt.dirtyFiles > 0 {
                reasons.append(Reason(.keep, "\(plural(wt.dirtyFiles, "uncommitted or untracked file")) would be lost"))
            }
            if wt.detachedOnlyCommits > 0 {
                reasons.append(Reason(.keep, "\(plural(wt.detachedOnlyCommits, "commit")) exist only in this detached checkout"))
            }
            if wt.unmergedCommits > 0, let branch = wt.branch {
                let target = wt.defaultBranch ?? "the default branch"
                reasons.append(Reason(.safe, "Branch \(branch) has \(plural(wt.unmergedCommits, "commit")) not in \(target) or on a remote. The branch stays in the repository; only this checkout goes"))
            } else if let branch = wt.branch, !wt.isOrphaned, wt.dirtyFiles == 0 {
                reasons.append(Reason(.safe, "Clean checkout of \(branch), already merged or pushed"))
            }
        }

        if !crumb.secrets.isEmpty {
            let shown = crumb.secrets.prefix(3).joined(separator: ", ")
            let more = crumb.secrets.count > 3 ? " and more" : ""
            reasons.append(Reason(.caution, "Contains files that look like secrets: \(shown)\(more)"))
        }

        if let activity = crumb.lastActivity {
            let idle = now.timeIntervalSince(activity)
            let days = Int(idle / 86_400)
            let subject = rule.activity == .parent ? "Project changed" : "Changed"
            if idle < 86_400 {
                let hours = max(0, Int(idle / 3_600))
                reasons.append(Reason(.keep, "\(subject) \(hours == 0 ? "just now" : "\(plural(hours, "hour")) ago")"))
            } else if days < rule.minIdleDays {
                reasons.append(Reason(.caution, "\(subject) \(plural(days, "day")) ago; this kind waits \(rule.minIdleDays) days"))
            } else {
                reasons.append(Reason(.safe, "Untouched for \(plural(days, "day"))"))
            }
        }

        if rule.regenerable {
            reasons.append(Reason(.safe, "Regenerable: \(rule.description)"))
        }

        let verdict = reasons.map(\.level).max() ?? .safe
        return (verdict, reasons.sorted { $0.level > $1.level })
    }

    static func plural(_ n: Int, _ word: String) -> String {
        "\(n) \(word)\(n == 1 ? "" : "s")"
    }
}
