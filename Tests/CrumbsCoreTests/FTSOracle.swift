@testable import CrumbsCore
import Darwin
import Foundation

/// The straightforward fts(3) walk. Slow, obviously correct: the bulk reader
/// must agree with it byte for byte.
enum FTSOracle {
    struct Stats: Equatable {
        var size: Int64 = 0
        var fileCount = 0
        var newestSeconds = 0
    }

    static func stats(of directory: String) -> Stats {
        var stats = Stats()
        var linked: [String: (seen: Int, links: Int, bytes: Int64)] = [:]
        guard let root = strdup(directory) else { return stats }
        defer { free(root) }
        var paths: [UnsafeMutablePointer<CChar>?] = [root, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return stats }
        defer { fts_close(fts) }
        var quietLevel: Int?
        while let entry = fts_read(fts) {
            let e = entry.pointee
            let level = Int(e.fts_level)
            let name = String(cString: e.fts_path + (Int(e.fts_pathlen) - Int(e.fts_namelen)))
            switch Int32(e.fts_info) {
            case FTS_D:
                if quietLevel == nil, level > 0, SizeInspector.isQuiet(name) { quietLevel = level }
            case FTS_DP:
                if quietLevel == level { quietLevel = nil }
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let st = e.fts_statp?.pointee else { continue }
                let bytes = Int64(st.st_blocks) * 512
                if st.st_nlink > 1, Int32(e.fts_info) == FTS_F {
                    let key = "\(st.st_dev):\(st.st_ino)"
                    var record = linked[key] ?? (0, Int(st.st_nlink), bytes)
                    record.seen += 1
                    linked[key] = record
                } else {
                    stats.size += bytes
                }
                stats.fileCount += 1
                if quietLevel == nil { stats.newestSeconds = max(stats.newestSeconds, st.st_mtimespec.tv_sec) }
            default:
                continue
            }
        }
        for record in linked.values where record.seen >= record.links { stats.size += record.bytes }
        return stats
    }
}
