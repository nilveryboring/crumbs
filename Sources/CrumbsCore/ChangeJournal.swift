import CoreServices
import Foundation

/// A point in macOS's own record of file changes (FSEvents). Kept between
/// scans so the next one can ask "what changed since?" instead of reading
/// every file again.
public struct ScanMark: Codable, Sendable, Equatable {
    public var eventID: UInt64
    /// The record's identity on the volume. A new one means the old record
    /// is gone and the mark is worthless.
    public var volume: String
}

/// What one scan leaves for the next.
public struct ScanMemory: Codable, Sendable {
    public var mark: ScanMark
    /// The mark of the scan before that one. macOS can report a change a few
    /// seconds late, after a scan has already asked, so each scan asks from
    /// one scan further back and nothing slips between two of them.
    public var earlier: ScanMark?
    /// When every folder was last read in full. A full read is repeated
    /// daily in case the change record ever missed something.
    public var fullScan: Date

    public init(mark: ScanMark, earlier: ScanMark? = nil, fullScan: Date) {
        self.mark = mark
        self.earlier = earlier
        self.fullScan = fullScan
    }
}

public enum ChangeJournal {
    public struct Changes: Sendable {
        /// Every folder something changed in, and each folder above it.
        var touched: Set<String> = []
        /// Folders macOS says to read again top to bottom.
        var deep: [String] = []

        public func touches(_ path: String) -> Bool {
            touched.contains(path) || deep.contains { path.hasPrefix($0 + "/") }
        }

        mutating func add(_ raw: String, deep isDeep: Bool) {
            var path = raw
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            if isDeep { deep.append(path) }
            while path.count > 1, touched.insert(path).inserted {
                path = (path as NSString).deletingLastPathComponent
            }
        }
    }

    /// Now, as a mark. Nil when the roots are on more than one volume or the
    /// volume keeps no change record.
    public static func mark(roots: [String]) -> ScanMark? {
        var devices = Set<dev_t>()
        for root in roots {
            var info = stat()
            guard stat(root, &info) == 0 else { continue }
            devices.insert(info.st_dev)
        }
        guard devices.count == 1, let device = devices.first,
              let uuid = FSEventsCopyUUIDForDevice(device) else { return nil }
        return ScanMark(eventID: FSEventsGetCurrentEventId(), volume: CFUUIDCreateString(nil, uuid) as String)
    }

    /// The folders changed under `roots` since `mark`. Nil when that cannot
    /// be known for sure, and everything has to be read again.
    public static func changes(since mark: ScanMark, roots: [String], timeout: TimeInterval = 20) -> Changes? {
        guard let now = self.mark(roots: roots), now.volume == mark.volume, now.eventID >= mark.eventID else { return nil }
        let collector = Collector()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(collector).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let collector = Unmanaged<Collector>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: NSArray.self)
            for index in 0..<count {
                let flag = Int(flags[index])
                if flag & (kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                    | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged) != 0 {
                    collector.failed = true
                }
                if flag & kFSEventStreamEventFlagHistoryDone != 0 {
                    collector.done.signal()
                    continue
                }
                if let path = paths[index] as? String {
                    collector.changes.add(path, deep: flag & kFSEventStreamEventFlagMustScanSubDirs != 0)
                }
            }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, roots as CFArray, mark.eventID, 0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)) else { return nil }
        let queue = DispatchQueue(label: "crumbs.change-journal")
        FSEventStreamSetDispatchQueue(stream, queue)
        defer {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        guard FSEventStreamStart(stream) else { return nil }
        guard collector.done.wait(timeout: .now() + timeout) == .success else { return nil }
        FSEventStreamFlushSync(stream) // changes from the last moments, not yet written to the record
        return queue.sync { collector.failed ? nil : collector.changes }
    }

    /// Only touched on the stream's queue until the stream is done.
    private final class Collector: @unchecked Sendable {
        var changes = Changes()
        var failed = false
        let done = DispatchSemaphore(value: 0)
    }
}
