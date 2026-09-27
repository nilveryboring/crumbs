import Darwin
import Foundation

/// Which running processes sit inside a folder. A shell, dev server or agent
/// whose working directory is inside a crumb means someone is still using it.
public struct ProcessSnapshot: Sendable {
    struct Entry: Sendable {
        var ref: ProcessRef
        var cwd: String
    }

    let entries: [Entry]

    public static func capture() -> ProcessSnapshot {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return ProcessSnapshot(entries: []) }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let me = getpid()
        var entries: [Entry] = []
        for pid in pids.prefix(Int(max(filled, 0))) where pid > 0 && pid != me {
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { continue }
            let cwd = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            guard !cwd.isEmpty, cwd != "/" else { continue }
            var name = [CChar](repeating: 0, count: 256)
            let length = Int(proc_name(pid, &name, UInt32(name.count)))
            let processName = String(decoding: name.prefix(max(0, length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            entries.append(Entry(ref: ProcessRef(pid: pid, name: processName), cwd: cwd))
        }
        return ProcessSnapshot(entries: entries)
    }

    public func processes(inside path: String) -> [ProcessRef] {
        let root = canonicalPath(path)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return entries.filter { $0.cwd == root || $0.cwd.hasPrefix(prefix) }.map(\.ref)
    }
}
