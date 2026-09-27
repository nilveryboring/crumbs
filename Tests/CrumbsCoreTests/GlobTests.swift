@testable import CrumbsCore
import Foundation
import Testing

@Suite struct GlobTests {
    @Test func doubleStarMatchesAnyDepth() {
        let glob = Glob("**/node_modules")
        #expect(glob.matches("/Users/a/Code/app/node_modules"))
        #expect(glob.matches("/node_modules"))
        #expect(!glob.matches("/Users/a/Code/app/node_modules/react"))
    }

    @Test func singleStarStaysInOneComponent() {
        let glob = Glob("~/.codex/worktrees/*/*", home: "/Users/a")
        #expect(glob.matches("/Users/a/.codex/worktrees/2263/webapp"))
        #expect(!glob.matches("/Users/a/.codex/worktrees/2263"))
        #expect(!glob.matches("/Users/a/.codex/worktrees/2263/webapp/src"))
        #expect(!glob.matches("/Users/b/.codex/worktrees/2263/webapp"))
    }

    @Test func claudeWorktreesAnywhere() {
        let glob = Glob("**/.claude/worktrees/*")
        #expect(glob.matches("/Users/a/Code/site/.claude/worktrees/agent-a4c2"))
        #expect(!glob.matches("/Users/a/Code/site/.claude/worktrees"))
    }

    @Test func secretNames() {
        #expect(SecretNames.looksSecret(".env"))
        #expect(SecretNames.looksSecret(".env.production"))
        #expect(!SecretNames.looksSecret(".env.example"))
        #expect(SecretNames.looksSecret("realtime-production-secrets.json"))
        #expect(SecretNames.looksSecret("AuthKey_ABC.p8"))
        #expect(SecretNames.looksSecret("google-oauth-secret.txt"))
        #expect(SecretNames.looksSecret("client_secret.json"))
        #expect(SecretNames.looksSecret("api-key.txt"))
        #expect(!SecretNames.looksSecret("ai-secret-santa-form-generator.json"))
        #expect(!SecretNames.looksSecret("secretary.png"))
        #expect(!SecretNames.looksSecret("keyboard.json"))
        #expect(!SecretNames.looksSecret("index.ts"))
    }

    @Test func builtInRulesLoad() {
        let rules = Rule.builtIn()
        #expect(rules.count >= 10)
        #expect(Set(rules.map(\.id)).count == rules.count)
    }
}

@Suite struct BulkReaderTests {
    @Test func agreesWithFTS() throws {
        let root = canonicalPath(NSTemporaryDirectory()) + "/crumbs-bulk-\(UUID().uuidString)"
        let fm = FileManager.default
        for i in 0..<40 {
            let dir = root + "/d\(i % 5)/sub\(i % 3)"
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try String(repeating: "z", count: i * 997).write(toFile: dir + "/f\(i).txt", atomically: true, encoding: .utf8)
        }
        try fm.createDirectory(atPath: root + "/node_modules/x", withIntermediateDirectories: true)
        try "q".write(toFile: root + "/node_modules/x/i.js", atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: root + "/link", withDestinationPath: "/usr")
        try fm.linkItem(atPath: root + "/d1/sub1/f1.txt", toPath: root + "/hard.txt")
        defer { try? fm.removeItem(atPath: root) }

        let bulk = SizeInspector.stats(of: root, lookForSecrets: false)
        let oracle = FTSOracle.stats(of: root)
        #expect(bulk.size == oracle.size)
        #expect(bulk.fileCount == oracle.fileCount)
        #expect(Int(bulk.newestModification?.timeIntervalSince1970 ?? 0) == oracle.newestSeconds)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CRUMBS_PROBE"] != nil))
    func agreesWithFTSOnRealFolders() {
        for path in ProcessInfo.processInfo.environment["CRUMBS_PROBE"]!.split(separator: ":").map(String.init) {
            let bulk = SizeInspector.stats(of: path, lookForSecrets: false)
            let oracle = FTSOracle.stats(of: path)
            #expect(bulk.size == oracle.size, "\(path)")
            #expect(bulk.fileCount == oracle.fileCount, "\(path)")
        }
    }
}
