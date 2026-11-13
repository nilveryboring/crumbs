import Foundation

/// Chats that Claude Code started in Codex through the Codex plugin. Every
/// review or rescue it hands over becomes a "Codex Companion Task: …" chat in
/// Codex's list, and nobody opens them again.
public enum CodexChats {
    public static let ruleID = "codex-companion-chat"
    static let titlePrefix = "Codex Companion Task: "

    public struct Chat: Sendable {
        public var path: String
        public var sessionID: String
        public var title: String?
    }

    /// `$CODEX_HOME`, else `~/.codex`, when it exists.
    public static func defaultHome() -> String? {
        let env = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? ""
        let home = env.isEmpty ? (NSHomeDirectory() as NSString).appendingPathComponent(".codex") : env
        return FileManager.default.fileExists(atPath: home) ? canonicalPath(home) : nil
    }

    /// Walks `<home>/sessions/YYYY/MM/DD/rollout-*.jsonl` and keeps the ones
    /// whose first line says Claude Code started them.
    public static func find(home: String) -> [Chat] {
        let titles = titles(home: home)
        var chats: [Chat] = []
        var stack = [home + "/sessions"]
        while let directory = stack.popLast() {
            BulkDirectory.forEach(directory) { entry in
                let name = entry.name
                if entry.isDirectory { stack.append(directory + "/" + name); return }
                guard entry.isRegularFile, name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"),
                      let id = sessionID(fileName: name) else { return }
                let path = directory + "/" + name
                guard startedByClaudeCode(path) else { return }
                chats.append(Chat(path: path, sessionID: id, title: titles[id]))
            }
        }
        return chats
    }

    /// `rollout-2026-11-12T17-40-04-<uuid>.jsonl` → `<uuid>`.
    static func sessionID(fileName: String) -> String? {
        let stem = fileName.dropLast(".jsonl".count)
        guard stem.count > 36 else { return nil }
        let id = String(stem.suffix(36))
        return UUID(uuidString: id) == nil ? nil : id
    }

    /// The session header is the first line and names who started the chat
    /// before the long instructions text, so the first few KB are enough.
    static func startedByClaudeCode(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8_192) else { return false }
        let head = String(decoding: data, as: UTF8.self)
        let firstLine = head.prefix { $0 != "\n" }
        return firstLine.contains("\"type\":\"session_meta\"") && firstLine.contains("\"originator\":\"Claude Code\"")
    }

    /// Chat names as Codex shows them, from `session_index.jsonl`. Later lines win.
    static func titles(home: String) -> [String: String] {
        struct Line: Decodable {
            var id: String
            var thread_name: String?
        }
        guard let data = FileManager.default.contents(atPath: home + "/session_index.jsonl") else { return [:] }
        let decoder = JSONDecoder()
        var titles: [String: String] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? decoder.decode(Line.self, from: line), var name = entry.thread_name else { continue }
            if name.hasPrefix(titlePrefix) { name.removeFirst(titlePrefix.count) }
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { titles[entry.id] = name }
        }
        return titles
    }

    static func stats(of path: String) -> (size: Int64, modified: Date?) {
        let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.totalFileAllocatedSizeKey, .contentModificationDateKey])
        return (Int64(values?.totalFileAllocatedSize ?? 0), values?.contentModificationDate)
    }

    // MARK: Forgetting

    /// Apps launched from Finder get a bare PATH, so find codex ourselves.
    static let codex: String? = {
        let home = NSHomeDirectory()
        var candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", home + "/.local/bin/codex",
                          home + "/.npm-global/bin/codex", home + "/.bun/bin/codex"]
        let nvm = home + "/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm))?.sorted(by: >) ?? []
        candidates += versions.map { "\(nvm)/\($0)/bin/codex" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// After the transcript is in the Trash, asks Codex to drop the chat from
    /// its own list. Codex keeps that list in a database only it should write.
    /// Returns false when Codex still lists the chat.
    static func forget(sessionID: String, transcript: String) -> Bool {
        guard let codex else { return false }
        // <home>/sessions/YYYY/MM/DD/rollout-….jsonl
        var home = transcript as NSString
        for _ in 0..<5 { home = home.deletingLastPathComponent as NSString }
        let bin = (codex as NSString).deletingLastPathComponent
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let result = Shell.run(codex, ["delete", "--force", sessionID],
                               environment: ["CODEX_HOME": home as String, "PATH": bin + ":" + path])
        return result.status == 0
    }
}
