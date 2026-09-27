import Foundation

enum Shell {
    struct Result {
        var status: Int32
        var output: String
    }

    /// Apps launched from Finder get a bare PATH, so find git ourselves.
    static let git: String = {
        for candidate in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/usr/bin/git"
    }()

    static func run(_ executable: String, _ arguments: [String], in directory: String? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0" // never take index.lock while another agent is committing
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return Result(status: -1, output: "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(status: process.terminationStatus, output: text)
    }

    static func git(_ arguments: [String], in directory: String) -> Result {
        run(git, ["-C", directory] + arguments)
    }
}

/// `realpath(3)`. Foundation's `resolvingSymlinksInPath` strips `/private`,
/// which breaks comparisons with the kernel's view of `/private/tmp`.
func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}
