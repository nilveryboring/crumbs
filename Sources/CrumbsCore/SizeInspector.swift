import Darwin
import Foundation

struct DirectoryStats {
    /// Bytes that actually come back when the folder goes: hard-linked files
    /// count only when every link lives inside the folder (pnpm stores don't).
    var size: Int64 = 0
    var fileCount = 0
    var newestModification: Date?
    var secrets: [String] = []
}

enum SizeInspector {
    /// One pass over the tree: reclaimable size, file count, newest mtime and
    /// file names that look like credentials. Symlinks are not followed and
    /// mount points are not crossed.
    static func stats(of directory: String, lookForSecrets: Bool) -> DirectoryStats {
        var stats = DirectoryStats()
        var linked: [HardLinkKey: (seen: Int, links: Int, bytes: Int64)] = [:]
        var newest = 0
        var rootDevice: Int32?
        // Inside node_modules, .git and app bundles, files still count toward
        // size but not toward "recently used" or the secret list.
        var stack: [(path: String, relative: String, quiet: Bool)] = [(directory, "", false)]

        while let (path, relative, quiet) = stack.popLast() {
            BulkDirectory.forEach(path) { entry in
                if rootDevice == nil { rootDevice = entry.device }
                if entry.isDirectory {
                    guard entry.device == rootDevice else { return }
                    let name = entry.name
                    stack.append((path + "/" + name, relative.isEmpty ? name : relative + "/" + name,
                                  quiet || isQuiet(name)))
                    return
                }
                if entry.linkCount > 1, entry.isRegularFile {
                    let key = HardLinkKey(device: entry.device, inode: entry.fileID)
                    var record = linked[key] ?? (0, Int(entry.linkCount), entry.allocatedSize)
                    record.seen += 1
                    linked[key] = record
                } else {
                    stats.size += entry.allocatedSize
                }
                stats.fileCount += 1
                guard !quiet else { return }
                newest = max(newest, entry.modifiedSeconds)
                if lookForSecrets, stats.secrets.count < 8 {
                    let name = entry.name
                    if SecretNames.looksSecret(name) {
                        stats.secrets.append(relative.isEmpty ? name : relative + "/" + name)
                    }
                }
            }
        }

        for record in linked.values where record.seen >= record.links { stats.size += record.bytes }
        if newest > 0 { stats.newestModification = Date(timeIntervalSince1970: TimeInterval(newest)) }
        stats.secrets.sort()
        return stats
    }

    private struct HardLinkKey: Hashable {
        var device: Int32
        var inode: UInt64
    }

    static func isQuiet(_ name: String) -> Bool {
        name == "node_modules" || name == ".git" || name.hasSuffix(".app") || name.hasSuffix(".xcarchive")
            || name.hasSuffix(".framework") || name.hasSuffix(".appex")
    }

    /// Newest mtime among a folder's direct children: cheap "is this project alive".
    static func shallowNewestModification(of directory: String) -> Date? {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? []
        return children.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }
}

enum SecretNames {
    static func looksSecret(_ name: String) -> Bool {
        let lower = name.lowercased()
        if [".env", ".dev.vars", ".npmrc", ".netrc", ".pypirc", "auth.json", "credentials"].contains(lower) { return true }
        if lower.hasPrefix(".env."), !["example", "sample", "template", "defaults"].contains(where: lower.hasSuffix) {
            return true
        }
        if lower.hasPrefix("id_rsa") || lower.hasPrefix("id_ed25519") { return true }
        let ext = (lower as NSString).pathExtension
        if ["pem", "p12", "pfx", "p8", "keystore", "jks"].contains(ext) { return true }
        guard ["json", "txt", "yaml", "yml", "toml", "key", ""].contains(ext) else { return false }
        // Whole words only: "secrets.json" yes, "ai-secret-santa-form.json" no.
        let words = (lower as NSString).deletingPathExtension
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let strong: Set = ["secrets", "credentials", "credential", "serviceaccount", "privatekey"]
        if words.contains(where: strong.contains) { return true }
        // "client_secret", "api-key", "access_token", "google-oauth-secret".
        let qualifiers: Set = ["secret", "api", "private", "access", "oauth", "client"]
        guard let last = words.last, ["secret", "key", "token"].contains(last) else { return false }
        return words.contains(where: qualifiers.contains)
    }
}
