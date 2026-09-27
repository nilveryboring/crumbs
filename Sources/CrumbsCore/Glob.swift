import Foundation

/// Path glob over components: `*` matches within a component (fnmatch),
/// `**` matches zero or more whole components, `~` expands to home.
public struct Glob: Sendable, Hashable {
    let components: [String]

    public init(_ pattern: String, home: String = NSHomeDirectory()) {
        var p = pattern
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + p.dropFirst(1) }
        components = p.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        anchored = p.hasPrefix("/")
    }

    let anchored: Bool

    /// Cheap prefilter: a literal last component must equal the name.
    public func couldMatch(lastComponent name: String) -> Bool {
        guard let last = components.last else { return false }
        if last.contains(where: { "*?[".contains($0) }) { return true }
        return last == name
    }

    public func matches(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // Unanchored patterns behave as if they started with `**`.
        let pattern = anchored ? components : ["**"] + components
        return Glob.match(pattern[...], parts[...])
    }

    private static func match(_ pattern: ArraySlice<String>, _ parts: ArraySlice<String>) -> Bool {
        guard let head = pattern.first else { return parts.isEmpty }
        if head == "**" {
            let rest = pattern.dropFirst()
            var remaining = parts
            while true {
                if match(rest, remaining) { return true }
                guard !remaining.isEmpty else { return false }
                remaining = remaining.dropFirst()
            }
        }
        guard let part = parts.first, fnmatch(head, part, 0) == 0 else { return false }
        return match(pattern.dropFirst(), parts.dropFirst())
    }
}
