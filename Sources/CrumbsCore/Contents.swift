import Foundation

/// What sits directly inside a crumb, biggest first. Answers "what is this
/// tmp folder, actually" without opening Finder.
public struct ContentEntry: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var fileCount: Int
    public var modified: Date?
}

public enum ContentsInspector {
    public static func topLevel(of directory: String, limit: Int = 8) -> (entries: [ContentEntry], more: Int) {
        var entries: [ContentEntry] = []
        BulkDirectory.forEach(directory) { entry in
            let name = entry.name
            if entry.isDirectory {
                let stats = SizeInspector.stats(of: directory + "/" + name, lookForSecrets: false)
                entries.append(ContentEntry(name: name, isDirectory: true, size: stats.size, fileCount: stats.fileCount,
                                            modified: stats.newestModification))
            } else {
                entries.append(ContentEntry(name: name, isDirectory: false, size: entry.allocatedSize, fileCount: 1,
                                            modified: Date(timeIntervalSince1970: TimeInterval(entry.modifiedSeconds))))
            }
        }
        entries.sort { $0.size > $1.size }
        return (Array(entries.prefix(limit)), max(0, entries.count - limit))
    }
}
