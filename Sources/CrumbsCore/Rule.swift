import Foundation

/// A kind of leftover Crumbs knows how to recognise. Rules live as JSON in
/// `Sources/CrumbsCore/Rules/` so adding one is a data-only pull request.
public struct Rule: Codable, Sendable, Hashable {
    public enum Activity: String, Codable, Sendable {
        /// Idle time comes from the newest file inside the crumb.
        case `self`
        /// Idle time comes from the project that owns the crumb (its direct
        /// children and last commit). Right for node_modules, dist, target…
        case parent
    }

    public var id: String
    public var name: String
    public var category: CrumbCategory
    public var description: String
    /// Path globs. `~` is the home folder, `*` matches inside one path
    /// component, `**` matches any number of components.
    public var patterns: [String]
    /// Only count the directory when git says it is ignored. Keeps tracked
    /// folders like a committed `build/` out of the list.
    public var requiresGitIgnored: Bool
    /// Only count the directory when a sibling with this name exists.
    public var requiresSibling: String?
    public var regenerable: Bool
    public var activity: Activity
    /// Below this many idle days the crumb is marked "Check" instead of "Safe".
    public var minIdleDays: Int
    /// After trashing, also trash the parent when it is left empty and matches
    /// this glob (Codex nests some worktrees in a per-task folder).
    public var emptyParentPattern: String?

    public init(id: String, name: String, category: CrumbCategory, description: String, patterns: [String],
                requiresGitIgnored: Bool = false, requiresSibling: String? = nil, regenerable: Bool,
                activity: Activity = .self, minIdleDays: Int, emptyParentPattern: String? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.description = description
        self.patterns = patterns
        self.requiresGitIgnored = requiresGitIgnored
        self.requiresSibling = requiresSibling
        self.regenerable = regenerable
        self.activity = activity
        self.minIdleDays = minIdleDays
        self.emptyParentPattern = emptyParentPattern
    }

    enum CodingKeys: String, CodingKey {
        case id, name, category, description, patterns, requiresGitIgnored, requiresSibling
        case regenerable, activity, minIdleDays, emptyParentPattern
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        category = try c.decode(CrumbCategory.self, forKey: .category)
        description = try c.decode(String.self, forKey: .description)
        patterns = try c.decode([String].self, forKey: .patterns)
        requiresGitIgnored = try c.decodeIfPresent(Bool.self, forKey: .requiresGitIgnored) ?? false
        requiresSibling = try c.decodeIfPresent(String.self, forKey: .requiresSibling)
        regenerable = try c.decode(Bool.self, forKey: .regenerable)
        activity = try c.decodeIfPresent(Activity.self, forKey: .activity) ?? .self
        minIdleDays = try c.decode(Int.self, forKey: .minIdleDays)
        emptyParentPattern = try c.decodeIfPresent(String.self, forKey: .emptyParentPattern)
    }

    /// Fallback for linked git worktrees no specific rule claims.
    public static let genericWorktree = Rule(
        id: "git-worktree",
        name: "Git worktree",
        category: .worktree,
        description: "A linked git worktree. Removing the folder keeps the branch in the main repository.",
        patterns: [],
        regenerable: false,
        minIdleDays: 7
    )

    public static func builtIn() -> [Rule] {
        guard let dir = Bundle.module.url(forResource: "Rules", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? decoder.decode(Rule.self, from: Data(contentsOf: $0)) }
    }
}
