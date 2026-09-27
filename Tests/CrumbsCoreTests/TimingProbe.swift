@testable import CrumbsCore
import Foundation
import Testing

@Test(.enabled(if: ProcessInfo.processInfo.environment["CRUMBS_PROBE"] != nil))
func timingProbe() async {
    let scanner = CrumbScanner()
    var t = Date()
    let candidates = scanner.discover(roots: CrumbScanner.defaultRoots())
    print("PROBE discover \(candidates.count) in \(Date().timeIntervalSince(t))s")
    t = Date()
    var gitTime = 0.0, sizeTime = 0.0
    for c in candidates.sorted(by: { $0.path < $1.path }).prefix(400) {
        let t1 = Date(); _ = SizeInspector.stats(of: c.path, lookForSecrets: false); sizeTime += Date().timeIntervalSince(t1)
        if c.isWorktree { let t2 = Date(); _ = GitInspector.inspectWorktree(at: c.path); gitTime += Date().timeIntervalSince(t2) }
    }
    print("PROBE size \(sizeTime)s git \(gitTime)s total \(Date().timeIntervalSince(t))s")
}
