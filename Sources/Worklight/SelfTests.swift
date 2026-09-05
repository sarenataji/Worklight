import Foundation
import AppKit

@MainActor
enum SelfTests {
    static func run() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            count += 1
        }
        let activity = ProjectFileActivity.parse("2\t3\tfile with spaces.swift\n1\t0\tfile with spaces.swift\n-\t-\timage.png\ninvalid\n", repository: "/fixture")
        check(activity.count == 1 && activity[0].lines == 6 && activity[0].path == "file with spaces.swift", "Activity aggregates repeated paths and skips binary or malformed stats")
        let model = DashboardModel()
        let usage = AppUsage(id: "test", name: "Test app", icon: nil, application: nil, processes: [ProcessRow(pid: 123, parent: 1, uid: getuid(), cpu: 45, memoryMB: 1024, command: "/test/app")])
        model.performance.cpu = 20
        model.performance.memoryLevel = 1
        check(model.reasons(for: usage).isEmpty, "Healthy usage is filtered out")
        check(model.belongsInBackground(usage), "Quiet iconless process belongs in collapsed background section")
        model.apps = [usage]
        check(model.matchingApps(search: "  TEST  ", sortMemory: false).count == 1, "Search includes background names and trims whitespace")
        check(model.matchingApps(search: "123", sortMemory: true).count == 1, "Search finds background PID")
        check(model.matchingApps(search: "/test/app", sortMemory: false).count == 1, "Search finds process command")
        check(model.matchingApps(search: "missing", sortMemory: false).isEmpty, "Unmatched search is empty")
        let iconApp = AppUsage(id: "icon", name: "Desktop app", icon: NSImage(size: NSSize(width: 22, height: 22)), application: nil, processes: usage.processes)
        check(!model.belongsInBackground(iconApp), "Apps with icons stay visible")
        let idle = AppUsage(id: "idle", name: "Idle app", icon: iconApp.icon, application: nil, processes: [ProcessRow(pid: 456, parent: 1, uid: getuid(), cpu: 0, memoryMB: 2048, command: "/idle/app")])
        let roundedZero = AppUsage(id: "tiny", name: "Tiny CPU", icon: nil, application: nil, processes: [ProcessRow(pid: 789, parent: 1, uid: getuid(), cpu: 0.01, memoryMB: 1, command: "/tiny/app")])
        model.apps = [usage, idle, roundedZero]
        check(model.matchingApps(search: "", sortMemory: false).map(\.id) == [usage.id], "Zero and displayed-zero CPU rows are hidden")
        check(model.matchingApps(search: "  ", sortMemory: true).map(\.id) == [usage.id], "Idle rows stay hidden when sorting memory or searching whitespace")
        check(model.matchingApps(search: "idle", sortMemory: false).map(\.id) == [idle.id], "Search reveals idle apps")
        check(model.matchingApps(search: "789", sortMemory: false).map(\.id) == [roundedZero.id], "Search reveals idle background PID")
        model.performance.memoryLevel = 2
        check(model.reasons(for: usage).count == 1, "Large memory user flagged only under pressure")
        check(!model.belongsInBackground(usage), "Background memory contributor remains visible under pressure")
        model.performance.cpu = 80
        check(model.reasons(for: usage).count == 2, "CPU contributor has supporting overall CPU evidence")
        check(!usage.canQuit, "Raw background process cannot be quit")
        let fileFixture = " M file with spaces.txt\0?? new/fresh.txt\0R  renamed.txt\0old.txt\0"
        let files = ChangedFile.parse(fileFixture)
        check(files.count == 3 && files[0].path == "file with spaces.txt" && files[0].location == "Not staged", "File names and unstaged status")
        check(files[2].meaning == "Renamed" && files[2].path == "renamed.txt", "Rename source skipped")
        let fixture = "# branch.head main\n# branch.upstream origin/main\n# branch.ab +2 -3\n1 .M file\n? untracked\nu UU conflict"
        let parsed = Repository.parse(path: "/tmp/project", output: fixture)
        check(parsed.branch == "main" && parsed.upstream == "origin/main", "Branch headers")
        check(parsed.ahead == 2 && parsed.behind == 3, "Ahead/behind")
        check(parsed.changed == 3 && parsed.conflicts == 1 && !parsed.canPull, "Unsafe pull blocked")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("worklight-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote.git").path
        let local = root.appendingPathComponent("local").path
        let other = root.appendingPathComponent("other").path
        func command(_ args: [String], _ path: String = root.path) { let result = git(args, path: path); check(result.status == 0, "git \(args): \(result.output)") }
        command(["init", "--bare", remote])
        command(["clone", remote, local])
        command(["config", "user.name", "Worklight Test"], local)
        command(["config", "user.email", "test@example.invalid"], local)
        command(["checkout", "-b", "main"], local)
        try! "first".write(toFile: local + "/file.txt", atomically: true, encoding: .utf8)
        command(["add", "."], local); command(["commit", "-m", "Initial"], local)
        let collected = collectProjectActivity([local])
        check(collected.failed == 0 && collected.files.count == 1 && collected.files[0].lines == 1, "Activity reads committed lines from temporary repository")
        let unavailable = collectProjectActivity([root.appendingPathComponent("missing").path])
        check(unavailable.failed == 1 && unavailable.files.isEmpty, "Unavailable history is not presented as verified activity")
        command(["push", "-u", "origin", "main"], local)
        let initialPush = inspectRepository(local, fetch: false).activity
        check(initialPush?.pushedAt != nil && initialPush?.subject == "Initial", "Initial push confirmed from reflog")
        check(initialPush?.pushedCount == nil, "Initial push does not guess a count")
        command(["clone", "-b", "main", remote, other])
        command(["config", "user.name", "Worklight Test"], other)
        command(["config", "user.email", "test@example.invalid"], other)
        let cloned = inspectRepository(other, fetch: false).activity
        check(cloned?.subject == "Initial" && cloned?.pushedAt == nil, "Clone falls back to latest remote commit")
        try! "second".write(toFile: other + "/file.txt", atomically: true, encoding: .utf8)
        command(["commit", "-am", "Remote update"], other)
        check(inspectRepository(other, fetch: false).activity?.pushedAt == nil, "Unpushed commit is not reported as a push")
        let beforePush = Date().addingTimeInterval(-1)
        command(["push"], other)
        let pushed = inspectRepository(other, fetch: false)
        check(pushed.activity?.pushedCount == 1 && pushed.activity?.subject == "Remote update", "One-commit push counted")
        check((pushed.activity?.pushedAt ?? .distantPast) >= beforePush, "Push time comes from the push event")
        check(pushed.ahead == 0 && pushed.behind == 0, "Push activity preserves up-to-date counts")
        let incoming = inspectRepository(local, fetch: true)
        check(incoming.behind == 1 && incoming.canPull, "Detect actual remote commit")
        check(incoming.activity?.hash == initialPush?.hash && incoming.activity?.pushedAt == initialPush?.pushedAt, "Fetch preserves previous local push")
        check((try! String(contentsOfFile: local + "/file.txt")) == "first", "Fetch leaves working files alone")
        try! "local edit".write(toFile: local + "/file.txt", atomically: true, encoding: .utf8)
        let dirty = inspectRepository(local, fetch: false)
        check(dirty.files.count == 1 && dirty.files[0].path == "file.txt" && dirty.files[0].meaning == "Modified", "Actual modified file details")
        check(safePull(path: local).status != 0, "Dirty pull refused")
        check((try! String(contentsOfFile: local + "/file.txt")) == "local edit", "Local edit preserved")
        command(["restore", "file.txt"], local)
        check(safePull(path: local).status == 0, "Clean fast-forward pull")
        check((try! String(contentsOfFile: local + "/file.txt")) == "second", "Pulled correct file")
        check(inspectRepository(local, fetch: false).activity?.hash == initialPush?.hash, "Pull is not mistaken for a push")
        command(["commit", "--allow-empty", "-m", "First outgoing"], local)
        command(["commit", "--allow-empty", "-m", "Second outgoing"], local)
        command(["push"], local)
        let multiple = inspectRepository(local, fetch: false).activity
        check(multiple?.pushedCount == 2 && multiple?.subject == "Second outgoing", "Latest push replaces previous push and counts multiple commits")
        command(["pull", "--ff-only"], other)
        try! "local".write(toFile: local + "/local.txt", atomically: true, encoding: .utf8)
        command(["add", "."], local); command(["commit", "-m", "Local commit"], local)
        try! "third".write(toFile: other + "/file.txt", atomically: true, encoding: .utf8)
        command(["commit", "-am", "Another remote update"], other); command(["push"], other)
        let diverged = inspectRepository(local, fetch: true)
        check(diverged.ahead == 1 && diverged.behind == 1 && !diverged.canPull, "Divergence detected")
        check(safePull(path: local).status != 0, "Diverged pull refused")
        command(["reflog", "expire", "--expire=all", "refs/remotes/origin/main"], local)
        let expired = inspectRepository(local, fetch: false).activity
        check(expired?.pushedAt == nil && expired?.subject == "Another remote update", "Expired push history falls back to latest remote commit")
        command(["remote", "set-url", "origin", root.appendingPathComponent("missing.git").path], local)
        check(inspectRepository(local, fetch: true).error != nil, "Fetch failure visible")
        check(discoverRepositories(root: root.path).count == 2, "Repository discovery")
        let sampler = SystemSampler(); _ = sampler.sample(); Thread.sleep(forTimeInterval: 0.2)
        let snapshot = sampler.sample()
        check(snapshot.cpu >= 0 && snapshot.cpu <= 100 && !snapshot.processes.isEmpty, "Live CPU and process sampler")
        print("PASS: \(count) checks, including real Git fetch/pull, dirty files, divergence, failed remote, discovery, and live system sampling.")
    }
}
