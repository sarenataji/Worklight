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
        check(AppVersion("v0.10.0")! > AppVersion("0.9.9")!, "Release versions compare numerically")
        check(AppVersion("0.3.0") == AppVersion("v0.3.0"), "Release tags and bundle versions normalize")
        check(AppVersion("v1.2.3-beta") == nil && AppVersion("../1.2.3") == nil && AppVersion("1.2") == nil, "Malformed and prerelease version strings are rejected")
        let updateRelease = AppRelease(tag_name: "v0.4.0", draft: false, prerelease: false, assets: [.init(name: "Worklight-macOS-universal.zip", digest: nil)])
        check(updateRelease.isNewer(than: "0.3.0") && !updateRelease.isNewer(than: "0.4.0") && !updateRelease.isNewer(than: "0.5.0"), "Updater never offers equal versions or downgrades")
        check(!AppRelease(tag_name: "v0.4.0", draft: true, prerelease: false, assets: updateRelease.assets).isNewer(than: "0.3.0"), "Draft releases are ignored")
        check(!AppRelease(tag_name: "v0.4.0", draft: false, prerelease: true, assets: updateRelease.assets).isNewer(than: "0.3.0"), "Prereleases are ignored")
        check(!AppRelease(tag_name: "v0.4.0", draft: false, prerelease: false, assets: []).isNewer(than: "0.3.0"), "Releases without universal package are ignored")
        check(AppUpdateService.validArchivePaths("Worklight.app/\nWorklight.app/Contents/MacOS/Worklight"), "Expected app archive paths accepted")
        check(!AppUpdateService.validArchivePaths("Worklight.app/../../other") && !AppUpdateService.validArchivePaths("/Worklight.app/Contents") && !AppUpdateService.validArchivePaths("Other.app/file") && !AppUpdateService.validArchivePaths(""), "Archive traversal, absolute paths and unrelated bundles rejected")
        let epoch = Date(timeIntervalSince1970: 1_000_000)
        var work = WorkSessionStore(legacy: ["/old": 42])
        work.project = "/first"; work.resume(at: epoch)
        for second in stride(from: 5, through: 305, by: 5) {
            work.sample(at: epoch.addingTimeInterval(Double(second)), idle: Double(second - 5))
        }
        check(!work.active && work.pending?.seconds == 300, "Five minutes idle becomes reviewable time")
        check(work.totals()["/first"] == 5, "Idle interval is removed retrospectively from totals")
        work.sample(at: epoch.addingTimeInterval(310), idle: 0)
        work.resolveIdle(include: true, at: epoch.addingTimeInterval(310))
        check(work.active && work.pending == nil && work.totals()["/first"] == 310, "Including idle credits it exactly once and resumes")
        work.resolveIdle(include: true, at: epoch.addingTimeInterval(310))
        check(work.totals()["/first"] == 310, "Repeated idle resolution never duplicates time")
        work.sample(at: epoch.addingTimeInterval(315), idle: 0)
        work.pause("Paused manually")
        work.sample(at: epoch.addingTimeInterval(400), idle: 0)
        check(work.totals()["/first"] == 315, "Manual pause excludes elapsed time")
        work.project = "/second"; work.resume(at: epoch.addingTimeInterval(400))
        work.sample(at: epoch.addingTimeInterval(405), idle: 0)
        check(work.totals()["/second"] == 5 && work.totals()["/old"] == 42, "Switching separates projects and preserves legacy totals")
        work.sample(at: epoch.addingTimeInterval(500), idle: 0)
        check(!work.active && work.totals()["/second"] == 5, "Long sampling gaps pause without credit")
        work.resume(at: epoch.addingTimeInterval(500))
        work.sample(at: epoch.addingTimeInterval(495), idle: 0)
        check(!work.active, "Backward clock changes pause")
        work.resume(at: epoch.addingTimeInterval(600))
        work.sample(at: epoch.addingTimeInterval(605), idle: 400)
        check(work.pending?.start == epoch.addingTimeInterval(600), "Idle review cannot predate session start")
        work.resolveIdle(include: false, at: epoch.addingTimeInterval(605))
        check(work.totals()["/second"] == 5 && work.active, "Excluding idle resumes without credit")
        let savedTime = try! JSONEncoder().encode(work)
        let restoredTime = try! JSONDecoder().decode(WorkSessionStore.self, from: savedTime)
        check(restoredTime.totals() == work.totals(), "Sessions and legacy totals survive serialization")
        let defaultsName = "Worklight.session-tests." + UUID().uuidString
        let testDefaults = UserDefaults(suiteName: defaultsName)!
        defer { testDefaults.removePersistentDomain(forName: defaultsName) }
        let legacyData = try! JSONEncoder().encode(WorkTimeLedger(seconds: ["/legacy": 123]))
        testDefaults.set(legacyData, forKey: "workTimeLedger.v1")
        let migrated = WorkTimeTracker(defaults: testDefaults)
        check(migrated.seconds(live: false) == 123, "Tracker migrates previous recorded totals")
        migrated.start(project: "/new"); migrated.save()
        let restarted = WorkTimeTracker(defaults: testDefaults)
        check(!restarted.active && restarted.project == "/new", "Restart restores project paused")
        check(testDefaults.data(forKey: "workTimeLedger.v1") == legacyData, "Migration leaves rollback data intact")
        var editable = WorkSessionStore()
        editable.sessions = [WorkSession(project: "/one", start: epoch, end: epoch.addingTimeInterval(60)),
                             WorkSession(project: "/two", start: epoch.addingTimeInterval(120), end: epoch.addingTimeInterval(180))]
        editable.pending = WorkSession(project: "/two", start: epoch.addingTimeInterval(200), end: epoch.addingTimeInterval(500))
        editable.project = "/two"
        testDefaults.set(try! JSONEncoder().encode(editable), forKey: "workSessions.v2")
        let editor = WorkTimeTracker(defaults: testDefaults)
        check(editor.store.pending?.seconds == 300 && !editor.active, "Pending idle survives restart without counting offline time")
        var edited = editable.sessions[0]
        edited.project = "/reassigned"; edited.end = epoch.addingTimeInterval(90)
        editor.edit(edited)
        check(editor.seconds(for: "/reassigned", live: false) == 90 && editor.seconds(for: "/one", live: false) == 0, "Editing reassigns and adjusts totals")
        edited.end = epoch.addingTimeInterval(130)
        check(!editor.canEdit(edited), "Overlapping edits are rejected")
        edited.start = epoch.addingTimeInterval(190); edited.end = epoch.addingTimeInterval(210)
        check(!editor.canEdit(edited), "Edits cannot overlap pending idle")
        edited.start = Date(); edited.end = Date().addingTimeInterval(60)
        check(!editor.canEdit(edited), "Future edits are rejected")
        testDefaults.set(Data("broken".utf8), forKey: "workSessions.v2")
        let corrupt = WorkTimeTracker(defaults: testDefaults)
        corrupt.start(project: "/blocked"); corrupt.save()
        check(corrupt.storageError != nil && corrupt.project == nil && testDefaults.data(forKey: "workSessions.v2") == Data("broken".utf8), "Corrupt storage disables tracking without overwriting data")
        check(WorkTimeLedger.display(0) == "0m 0s" && WorkTimeLedger.display(3661) == "1h 1m 1s", "Live time formats seconds and hours")
        var categoryRepo = Repository(path: "/fixture")
        check(ProjectCategory.classify(categoryRepo) == .unverified, "Unknown tracking is never up to date")
        categoryRepo.upstream = "origin/main"; categoryRepo.checked = Date()
        check(ProjectCategory.classify(categoryRepo) == .current, "Verified clean project is current")
        categoryRepo.changed = 2
        check(ProjectCategory.classify(categoryRepo) == .working, "Local edits are work in progress")
        categoryRepo.changed = 0; categoryRepo.ahead = 1
        check(ProjectCategory.classify(categoryRepo) == .working, "Outgoing commits are work in progress")
        categoryRepo.behind = 1
        check(ProjectCategory.classify(categoryRepo) == .attention, "Divergence needs attention")
        categoryRepo.ahead = 0
        check(ProjectCategory.classify(categoryRepo) == .attention, "Incoming updates need attention")
        categoryRepo.checked = nil
        check(ProjectCategory.classify(categoryRepo) == .unverified, "Unverified remote counts are not classified as current")
        categoryRepo.error = "Offline"
        check(ProjectCategory.classify(categoryRepo) == .attention, "Failed checks need attention")
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
        let updateTarget = root.appendingPathComponent("Installed.app")
        let updatePrepared = root.appendingPathComponent("Prepared.app")
        try! "old".write(to: updateTarget, atomically: true, encoding: .utf8)
        try! "new".write(to: updatePrepared, atomically: true, encoding: .utf8)
        try! AppUpdateService.replace(prepared: updatePrepared, target: updateTarget) { _ in true }
        check((try? String(contentsOf: updateTarget)) == "new", "Prepared update replaces only the requested temporary target")
        try! "broken".write(to: updatePrepared, atomically: true, encoding: .utf8)
        do {
            try AppUpdateService.replace(prepared: updatePrepared, target: updateTarget) { _ in false }
            check(false, "Failed launch must fail installation")
        } catch { check((try? String(contentsOf: updateTarget)) == "new", "Failed update launch restores previous app") }
        do {
            try AppUpdateService.replace(prepared: root.appendingPathComponent("missing-update"), target: updateTarget) { _ in true }
            check(false, "Missing prepared bundle must fail installation")
        } catch { check((try? String(contentsOf: updateTarget)) == "new", "Replacement failure preserves existing installation") }
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
