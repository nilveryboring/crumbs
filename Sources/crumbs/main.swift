import CrumbsCore
import Foundation

// Read-only on purpose: the CLI reports, the app trashes.
let usage = """
usage: crumbs scan [--json] [--all] [path ...]

Lists what AI coding agents and build tools left behind, with a verdict and
the reasons for it. Defaults to your usual code folders, agent worktree
folders, /private/tmp and Xcode DerivedData. Hides crumbs under 1 MB unless
--all is given. Never deletes anything.
"""

var arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.first == "scan" else {
    print(usage)
    exit(arguments.isEmpty || arguments.first == "--help" || arguments.first == "-h" ? 0 : 64)
}
arguments.removeFirst()
let json = arguments.contains("--json")
let showAll = arguments.contains("--all")
let paths = arguments.filter { !$0.hasPrefix("--") }
let roots = paths.isEmpty ? CrumbScanner.defaultRoots() : paths

let started = Date()
let crumbs = await CrumbScanner().scan(roots: roots) { progress in
    guard !json, progress.total > 0 else { return }
    FileHandle.standardError.write("\r\(progress.phase) \(progress.completed)/\(progress.total)".data(using: .utf8)!)
}
if !json { FileHandle.standardError.write("\r\u{1B}[K".data(using: .utf8)!) }

let visible = showAll ? crumbs : crumbs.filter { $0.size >= 1_000_000 }

if json {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    FileHandle.standardOutput.write(try encoder.encode(visible))
    print()
    exit(0)
}

func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
let dot: [Verdict: String] = [.safe: "\u{1B}[32m●\u{1B}[0m", .caution: "\u{1B}[33m●\u{1B}[0m", .keep: "\u{1B}[31m●\u{1B}[0m"]
let home = NSHomeDirectory()

print("Scanned \(roots.count) roots in \(String(format: "%.1f", Date().timeIntervalSince(started)))s\n")
for crumb in visible {
    let path = crumb.path.hasPrefix(home) ? "~" + crumb.path.dropFirst(home.count) : crumb.path
    print("\(dot[crumb.verdict]!) \(bytes(crumb.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(crumb.ruleName.padding(toLength: 22, withPad: " ", startingAt: 0)) \(path)")
    for reason in crumb.reasons where reason.level != .safe || crumb.verdict == .safe {
        print("    \(dot[reason.level]!) \(reason.text)")
        if crumb.verdict == .safe { break }
    }
}

let byVerdict = Dictionary(grouping: visible, by: \.verdict).mapValues { $0.reduce(0) { $0 + $1.size } }
print("""

\(visible.count) crumbs, \(bytes(visible.reduce(0) { $0 + $1.size })) total
  \(dot[.safe]!) safe  \(bytes(byVerdict[.safe] ?? 0))
  \(dot[.caution]!) check \(bytes(byVerdict[.caution] ?? 0))
  \(dot[.keep]!) keep  \(bytes(byVerdict[.keep] ?? 0))
""")
