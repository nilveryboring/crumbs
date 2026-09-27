import Foundation

public struct TrashOutcome: Sendable {
    public var path: String
    public var trashedTo: String?
    public var error: String?
    public var freed: Int64
}

public enum Trasher {
    /// Moves crumbs to the Trash (never deletes), then lets git forget any
    /// worktree it just lost so `git worktree list` stays honest.
    public static func trash(_ crumbs: [Crumb]) -> [TrashOutcome] {
        let fm = FileManager.default
        var outcomes: [TrashOutcome] = []
        var repositoriesToPrune = Set<String>()

        for crumb in crumbs {
            let url = URL(fileURLWithPath: crumb.path)
            var resulting: NSURL?
            do {
                try fm.trashItem(at: url, resultingItemURL: &resulting)
                outcomes.append(TrashOutcome(path: crumb.path, trashedTo: resulting?.path, error: nil, freed: crumb.size))
                if let commonDir = crumb.worktree?.commonDir { repositoriesToPrune.insert(commonDir) }
                let parent = url.deletingLastPathComponent()
                if let pattern = crumb.emptyParentPattern, Glob(pattern).matches(parent.path) {
                    let rest = (try? fm.contentsOfDirectory(atPath: parent.path))?.filter { $0 != ".DS_Store" } ?? ["?"]
                    if rest.isEmpty { try? fm.trashItem(at: parent, resultingItemURL: nil) }
                }
            } catch {
                outcomes.append(TrashOutcome(path: crumb.path, trashedTo: nil, error: error.localizedDescription, freed: 0))
            }
        }

        for commonDir in repositoriesToPrune { GitInspector.pruneWorktrees(commonDir: commonDir) }
        return outcomes
    }
}
