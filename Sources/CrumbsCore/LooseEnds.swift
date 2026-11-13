import Foundation
import SQLite3

/// Records that still point at something already gone: chats Codex lists
/// whose transcript is missing, and worktrees git lists whose folder is
/// missing. They take no space, but they clutter the tools that list them.
/// Usually left by a clean-up that was cut short.
public struct LooseEnds: Sendable, Equatable {
    public var codexHome: String?
    /// Ids of chats Codex lists although their transcript no longer exists.
    public var deadChats: [String] = []
    /// Repository → number of worktree records whose folder is gone.
    public var staleWorktrees: [String: Int] = [:]

    public var isEmpty: Bool { deadChats.isEmpty && staleWorktrees.isEmpty }
    public var staleWorktreeCount: Int { staleWorktrees.values.reduce(0, +) }

    public init(codexHome: String? = nil, deadChats: [String] = [], staleWorktrees: [String: Int] = [:]) {
        self.codexHome = codexHome
        self.deadChats = deadChats
        self.staleWorktrees = staleWorktrees
    }

    /// Asks git about `repositories` (main checkouts) and about every
    /// repository sitting directly inside one of `roots`.
    public static func find(codexHome: String? = CodexChats.defaultHome(), repositories: [String],
                            roots: [String] = []) -> LooseEnds {
        var ends = LooseEnds(codexHome: codexHome)
        if let codexHome { ends.deadChats = deadChats(home: codexHome) }
        var candidates = Set(repositories)
        for root in roots {
            BulkDirectory.forEach(root) { entry in
                if entry.isDirectory { candidates.insert(root + "/" + entry.name) }
            }
        }
        for repository in candidates {
            let count = GitInspector.staleWorktreeRecords(in: repository)
            if count > 0 { ends.staleWorktrees[repository] = count }
        }
        return ends
    }

    /// Asks Codex to drop the dead chats and git to prune the stale records.
    /// Returns what is still left afterwards.
    public func tidy() -> LooseEnds {
        if let codexHome {
            let ids = deadChats
            // One codex process per chat. Four lanes: thousands finish in minutes
            // without piling writers onto Codex's database.
            let lanes = 4
            DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                for index in stride(from: lane, to: ids.count, by: lanes) {
                    _ = CodexChats.forget(sessionID: ids[index], home: codexHome)
                }
            }
        }
        for repository in staleWorktrees.keys {
            GitInspector.pruneWorktrees(commonDir: repository + "/.git")
        }
        return LooseEnds.find(codexHome: codexHome, repositories: Array(staleWorktrees.keys))
    }

    /// Reads Codex's thread list (read-only) for chats of the kinds Crumbs
    /// clears whose transcript file is gone.
    static func deadChats(home: String) -> [String] {
        var db: OpaquePointer?
        let path = "file:" + (home + "/state_5.sqlite").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + "?mode=ro"
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2_000)
        let originators = CodexChats.rulesByOriginator.keys.map { "'\($0)'" }.joined(separator: ",")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, rollout_path FROM threads WHERE originator IN (\(originators))", -1, &statement, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(statement) }
        var dead: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let rollout = sqlite3_column_text(statement, 1) else { continue }
            if !FileManager.default.fileExists(atPath: String(cString: rollout)) { dead.append(String(cString: id)) }
        }
        return dead
    }
}
