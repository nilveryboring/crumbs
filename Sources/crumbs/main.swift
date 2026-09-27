import CrumbsCore
import Foundation

// Read-only on purpose: the CLI reports, the app trashes.
let usage = """
usage: crumbs scan [--json] [--all] [--days RULE=N ...] [--off RULE ...] [path ...]

Lists what AI coding agents and build tools left behind, with a verdict and
the reasons for it. Defaults to your usual code folders, agent worktree
folders, /private/tmp and Xcode DerivedData. Hides crumbs under 1 MB unless
--all is given. Never deletes anything.

  --days RULE=N   treat RULE as safe after N idle days (e.g. node-modules=60)
  --off RULE      skip RULE entirely
  --rules         list rule ids and their default days
"""

var arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.first == "scan" else {
    print(usage)
    exit(arguments.isEmpty || arguments.first == "--help" || arguments.first == "-h" ? 0 : 64)
}
arguments.removeFirst()
let json = arguments.contains("--json")
let showAll = arguments.contains("--all")

var overrides: [String: RuleOverride] = [:]
var paths: [String] = []
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    index += 1
    switch argument {
    case "--days", "--off":
        guard index < arguments.count else { print(usage); exit(64) }
        let value = arguments[index]
        index += 1
        if argument == "--off" {
            overrides[value, default: RuleOverride()].enabled = false
        } else {
            let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let days = Int(parts[1]) else { print(usage); exit(64) }
            overrides[parts[0], default: RuleOverride()].minIdleDays = days
        }
    case "--rules":
        for rule in Rule.builtIn() {
            print("\(rule.id.padding(toLength: 22, withPad: " ", startingAt: 0)) \(rule.minIdleDays) days  \(rule.name)")
        }
        exit(0)
    case let flag where flag.hasPrefix("--"):
        continue
    default:
        paths.append(argument)
    }
}
let known = Set(Rule.builtIn().map(\.id))
for id in overrides.keys where !known.contains(id) {
    FileHandle.standardError.write("unknown rule \(id); see crumbs scan --rules\n".data(using: .utf8)!)
    exit(64)
}
let roots = paths.isEmpty ? CrumbScanner.defaultRoots() : paths

let started = Date()
let crumbs = await CrumbScanner(rules: Rule.builtIn().applying(overrides)).scan(roots: roots) { progress in
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
