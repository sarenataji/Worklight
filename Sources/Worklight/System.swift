import Foundation
import AppKit
import Darwin

struct CommandResult {
    let status: Int32
    let output: String
}

// File-backed output avoids pipe-buffer deadlocks. All callers run off the UI thread.
func run(_ executable: String, _ arguments: [String], at directory: String? = nil, timeout: TimeInterval = 15) -> CommandResult {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: file.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: file) }
    guard let handle = try? FileHandle(forWritingTo: file) else { return .init(status: -1, output: "Cannot create command output") }
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=8"
    environment["LC_ALL"] = "C"
    process.environment = environment
    process.standardOutput = handle
    process.standardError = handle
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return .init(status: -1, output: error.localizedDescription) }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    let timedOut = process.isRunning
    if timedOut {
        process.terminate()
        Thread.sleep(forTimeInterval: 0.2)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    process.waitUntilExit()
    let output = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    return .init(status: timedOut ? -2 : process.terminationStatus, output: timedOut ? "Check timed out. Check your connection or Git credentials." : output.trimmingCharacters(in: .newlines))
}

struct ChangedFile: Identifiable {
    var id: String { path }
    let path: String
    let code: String
    var meaning: String {
        if code == "??" { return "Untracked" }
        if code.contains("U") || code == "AA" || code == "DD" { return "Conflict" }
        if code.contains("D") { return "Deleted" }
        if code.contains("R") { return "Renamed" }
        if code.contains("A") { return "Added" }
        if code.contains("M") { return "Modified" }
        return "Changed"
    }
    var location: String {
        if code == "??" { return "Not staged" }
        let chars = Array(code)
        let staged = chars.first != " "
        let unstaged = chars.count > 1 && chars[1] != " "
        return staged && unstaged ? "Staged + unstaged" : staged ? "Staged" : "Not staged"
    }
    static func parse(_ output: String) -> [ChangedFile] {
        let entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var files: [ChangedFile] = []
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            if entry.count >= 3 {
                let code = String(entry.prefix(2))
                files.append(ChangedFile(path: String(entry.dropFirst(3)), code: code))
                if code.contains("R") || code.contains("C") { index += 1 }
            }
            index += 1
        }
        return files
    }
}

struct Repository: Identifiable {
    var id: String { path }
    var path: String
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var branch = ""
    var upstream = ""
    var ahead = 0
    var behind = 0
    var changed = 0
    var conflicts = 0
    var files: [ChangedFile] = []
    var error: String?
    var checked: Date?
    var remoteURL: URL?
    var canPull: Bool { error == nil && !upstream.isEmpty && behind > 0 && ahead == 0 && changed == 0 && branch != "(detached)" }
    var headline: String {
        if error != nil { return "Check needed" }
        if conflicts > 0 { return "Resolve conflicts" }
        if branch == "(detached)" { return "Detached HEAD" }
        if upstream.isEmpty { return "No tracking branch" }
        if ahead > 0 && behind > 0 { return "Branches have diverged" }
        if behind > 0 { return "Updates available" }
        if ahead > 0 { return "Ready to push" }
        if changed > 0 { return "Local edits" }
        return "Up to date"
    }
    static func parse(path: String, output: String) -> Repository {
        var repo = Repository(path: path)
        for line in output.split(separator: "\n").map(String.init) {
            if line.hasPrefix("# branch.head ") { repo.branch = String(line.dropFirst(14)) }
            else if line.hasPrefix("# branch.upstream ") { repo.upstream = String(line.dropFirst(18)) }
            else if line.hasPrefix("# branch.ab ") {
                let counts = line.dropFirst(12).split(separator: " ")
                if counts.count == 2 { repo.ahead = Int(counts[0].dropFirst()) ?? 0; repo.behind = Int(counts[1].dropFirst()) ?? 0 }
            } else if ["1 ", "2 ", "u ", "? "].contains(where: { line.hasPrefix($0) }) {
                repo.changed += 1
                if line.hasPrefix("u ") { repo.conflicts += 1 }
            }
        }
        return repo
    }
}

func git(_ args: [String], path: String) -> CommandResult { run("/usr/bin/git", args, at: path, timeout: 25) }
func inspectRepository(_ path: String, fetch: Bool) -> Repository {
    var fetchError: String?
    let initial = git(["status", "--porcelain=v2", "--branch", "--untracked-files=normal"], path: path)
    guard initial.status == 0 else { var repo = Repository(path: path); repo.error = initial.output; return repo }
    let parsed = Repository.parse(path: path, output: initial.output)
    if fetch && !parsed.upstream.isEmpty {
        let remote = git(["config", "--get", "branch.\(parsed.branch).remote"], path: path)
        if remote.status == 0 && remote.output != "." {
            let result = git(["fetch", "--quiet", "--", remote.output], path: path)
            if result.status != 0 { fetchError = result.output }
        }
    }
    let status = git(["status", "--porcelain=v2", "--branch", "--untracked-files=normal"], path: path)
    var repo = Repository.parse(path: path, output: status.output)
    repo.error = status.status == 0 ? fetchError : status.output
    let files = git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], path: path)
    if files.status == 0 {
        repo.files = ChangedFile.parse(files.output)
        repo.changed = repo.files.count
    } else { repo.error = files.output }
    if fetch && repo.error == nil && !repo.upstream.isEmpty { repo.checked = Date() }
    let remote = git(["remote", "get-url", "origin"], path: path)
    if remote.status == 0 {
        var address = remote.output
        if address.hasPrefix("git@github.com:") { address = address.replacingOccurrences(of: "git@github.com:", with: "https://github.com/") }
        if address.hasSuffix(".git") { address = String(address.dropLast(4)) }
        if let url = URL(string: address), url.scheme == "https", url.host == "github.com" { repo.remoteURL = url }
    }
    return repo
}

func discoverRepositories(root: String) -> [String] {
    let fm = FileManager.default
    var results = [String]()
    let excluded: Set<String> = ["node_modules", "vendor", "Pods", "Library", "build", "dist", ".build"]
    func visit(_ url: URL, depth: Int) {
        guard depth < 4 else { return }
        if fm.fileExists(atPath: url.appendingPathComponent(".git").path) { results.append(url.path); return }
        guard let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles) else { return }
        for child in children {
            guard !excluded.contains(child.lastPathComponent), let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true else { continue }
            visit(child, depth: depth + 1)
        }
    }
    visit(URL(fileURLWithPath: root), depth: 0)
    return results.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}

func safePull(path: String) -> CommandResult {
    let fresh = inspectRepository(path, fetch: true)
    guard fresh.canPull else { return .init(status: -1, output: "Pull paused: the project must have a tracked branch, incoming commits, no outgoing commits, and no local edits. Refresh to see its current status.") }
    return git(["-c", "merge.autostash=false", "pull", "--ff-only", "--no-rebase"], path: path)
}

struct ProcessRow: Identifiable {
    var id: Int32 { pid }
    let pid: Int32
    let parent: Int32
    let uid: UInt32
    let cpu: Double
    let memoryMB: Double
    let command: String
    var name: String { URL(fileURLWithPath: command).lastPathComponent }
}
struct PerformanceSnapshot {
    var cpu: Double = 0
    var memoryLevel: Int = 0
    var swapGB: Double = 0
    var processes: [ProcessRow] = []
    var error: String?
}
final class SystemSampler {
    private var previous: [UInt64]?
    func sample() -> PerformanceSnapshot {
        var snapshot = PerformanceSnapshot()
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        if result == KERN_SUCCESS {
            let ticks = [UInt64(info.cpu_ticks.0), UInt64(info.cpu_ticks.1), UInt64(info.cpu_ticks.2), UInt64(info.cpu_ticks.3)]
            if let previous {
                let delta = zip(ticks, previous).map { $0 &- $1 }
                let total = delta.reduce(0, +)
                if total > 0 { snapshot.cpu = 100 * Double(total - delta[2]) / Double(total) }
            }
            previous = ticks
        } else { snapshot.error = "CPU readings are unavailable." }
        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 { snapshot.memoryLevel = Int(level) }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 { snapshot.swapGB = Double(swap.xsu_used) / 1_073_741_824 }
        let ps = run("/bin/ps", ["-axo", "pid=,ppid=,uid=,%cpu=,rss=,comm="], timeout: 4)
        if ps.status != 0 { snapshot.error = "Process readings are unavailable." }
        snapshot.processes = ps.output.split(separator: "\n").compactMap { line in
            let parts = line.split(maxSplits: 5, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 6, let pid = Int32(parts[0]), let parent = Int32(parts[1]), let uid = UInt32(parts[2]), let cpu = Double(parts[3]), let rss = Double(parts[4]) else { return nil }
            return ProcessRow(pid: pid, parent: parent, uid: uid, cpu: cpu, memoryMB: rss / 1024, command: String(parts[5]))
        }.sorted { $0.cpu > $1.cpu }
        return snapshot
    }
}
