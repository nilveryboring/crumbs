import Foundation

public struct TrashOutcome: Sendable {
    public var path: String
    public var trashedTo: String?
    public var error: String?
    public var freed: Int64
    /// For chats: false when the owning app still lists it after the move.
    public var forgotten: Bool?
}

public enum Trasher {
    /// Moves crumbs to the Trash, then lets git forget any worktree it just
    /// lost so `git worktree list` stays honest. With `permanently` the
    /// crumbs are deleted outright: the space is back at once and nothing
    /// can be put back, so callers ask the user first.
    public static func trash(_ crumbs: [Crumb], permanently: Bool = false) -> [TrashOutcome] {
        let fm = FileManager.default
        var outcomes: [TrashOutcome] = []
        var repositoriesToPrune = Set<String>()
        var chats: [(outcome: Int, sessionID: String)] = []

        for crumb in crumbs {
            let url = URL(fileURLWithPath: crumb.path)
            var resulting: NSURL?
            do {
                if permanently { try fm.removeItem(at: url) } else { try fm.trashItem(at: url, resultingItemURL: &resulting) }
                outcomes.append(TrashOutcome(path: crumb.path, trashedTo: resulting?.path, error: nil, freed: crumb.size,
                                             forgotten: nil))
                if let id = crumb.codexSessionID { chats.append((outcomes.count - 1, id)) }
                if let commonDir = crumb.worktree?.commonDir { repositoriesToPrune.insert(commonDir) }
                let parent = url.deletingLastPathComponent()
                if let pattern = crumb.emptyParentPattern, Glob(pattern).matches(parent.path) {
                    let rest = (try? fm.contentsOfDirectory(atPath: parent.path))?.filter { $0 != ".DS_Store" } ?? ["?"]
                    if rest.isEmpty {
                        if permanently { try? fm.removeItem(at: parent) } else { try? fm.trashItem(at: parent, resultingItemURL: nil) }
                    }
                }
            } catch {
                outcomes.append(TrashOutcome(path: crumb.path, trashedTo: nil, error: error.localizedDescription, freed: 0, forgotten: nil))
            }
        }

        // One codex process per chat; a few at a time keeps a thousand of them bearable.
        let forgotten = ForgetResults(count: chats.count)
        let jobs = chats.map { (sessionID: $0.sessionID, transcript: outcomes[$0.outcome].path) }
        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            forgotten.set(index, CodexChats.forget(sessionID: jobs[index].sessionID, transcript: jobs[index].transcript))
        }
        for (index, chat) in chats.enumerated() { outcomes[chat.outcome].forgotten = forgotten.values[index] }

        for commonDir in repositoriesToPrune { GitInspector.pruneWorktrees(commonDir: commonDir) }
        return outcomes
    }
}

private final class ForgetResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [Bool]

    init(count: Int) { values = Array(repeating: false, count: count) }

    func set(_ index: Int, _ value: Bool) {
        lock.lock()
        values[index] = value
        lock.unlock()
    }
}
