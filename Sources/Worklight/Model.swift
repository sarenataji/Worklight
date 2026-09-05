import SwiftUI
import AppKit

struct AppUsage: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    let application: NSRunningApplication?
    var processes: [ProcessRow]
    var cpu: Double { processes.reduce(0) { $0 + $1.cpu } }
    var memoryMB: Double { processes.reduce(0) { $0 + $1.memoryMB } }
    var canQuit: Bool {
        guard let application, application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              application.activationPolicy == .regular,
              !(application.bundleIdentifier ?? "").hasPrefix("com.apple.") else { return false }
        return processes.contains { $0.pid == application.processIdentifier && $0.uid == getuid() }
    }
}

@MainActor
final class DashboardModel: ObservableObject {
    @Published var repositories: [Repository] = []
    @Published var performance = PerformanceSnapshot()
    @Published var history: [Double] = []
    @Published var apps: [AppUsage] = []
    @Published var refreshing = false
    @Published var pulling: String?
    @Published var notice: String?
    @Published var root: String
    @Published var lastScan: Date?
    @Published var visible = false
    private let sampler = SystemSampler()
    private var started = false
    private var highCPUStart: [String: Date] = [:]
    private var lastFetch = Date.distantPast
    var incoming: Int { repositories.filter { $0.behind > 0 }.count }
    var needsAttention: Int { repositories.filter { $0.error != nil || $0.conflicts > 0 || ($0.ahead > 0 && $0.behind > 0) }.count }
    var memoryTitle: String {
        switch performance.memoryLevel { case 1: return "Comfortable"; case 2: return "Under pressure"; case 4: return "High pressure"; default: return "Unavailable" }
    }
    init() {
        root = UserDefaults.standard.string(forKey: "workspaceRoot") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/apps").path
        Task { start() }
    }
    func start() {
        guard !started else { return }; started = true
        refresh()
        Task {
            while !Task.isCancelled {
                let firstSample = history.isEmpty
                let sample = await Task.detached(priority: .utility) { [sampler] in
                    if firstSample { _ = sampler.sample(); try? await Task.sleep(nanoseconds: 250_000_000) }
                    return sampler.sample()
                }.value
                performance = sample
                history.append(sample.cpu)
                if history.count > 40 { history.removeFirst() }
                apps = group(sample.processes)
                let busy = Set(apps.filter { $0.cpu >= 80 }.map(\.id))
                highCPUStart = highCPUStart.filter { busy.contains($0.key) }
                for id in busy where highCPUStart[id] == nil { highCPUStart[id] = Date() }
                if Date().timeIntervalSince(lastFetch) > 300 && !refreshing && pulling == nil { refresh() }
                try? await Task.sleep(nanoseconds: visible ? 3_000_000_000 : 15_000_000_000)
            }
        }
    }
    func refresh(fetch: Bool = true) {
        guard !refreshing && pulling == nil else { return }
        refreshing = true
        let folder = root
        let previous = Dictionary(uniqueKeysWithValues: repositories.map { ($0.path, $0.checked) })
        Task {
            let repos = await Task.detached(priority: .utility) {
                discoverRepositories(root: folder).map { path -> Repository in
                    var repo = inspectRepository(path, fetch: fetch)
                    if repo.checked == nil { repo.checked = previous[path] ?? nil }
                    return repo
                }
            }.value
            repositories = repos
            lastScan = Date()
            if fetch { lastFetch = Date() }
            refreshing = false
        }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose the folder containing your Git projects."
        panel.directoryURL = URL(fileURLWithPath: root)
        if panel.runModal() == .OK, let url = panel.url {
            root = url.path; UserDefaults.standard.set(root, forKey: "workspaceRoot"); repositories = []; refresh()
        }
    }
    func pull(_ repo: Repository) {
        guard pulling == nil && !refreshing else { return }
        pulling = repo.path
        Task {
            let result = await Task.detached(priority: .userInitiated) { safePull(path: repo.path) }.value
            notice = result.status == 0 ? "\(repo.name) is updated. \(result.output)" : result.output
            pulling = nil
            refresh(fetch: false)
        }
    }
    func openVSCode(_ repo: Repository) {
        let app = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        NSWorkspace.shared.open([URL(fileURLWithPath: repo.path)], withApplicationAt: app, configuration: .init()) { _, error in
            if let error { Task { @MainActor in self.notice = error.localizedDescription } }
        }
    }
    func openT3(_ repo: Repository) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(repo.path, forType: .string)
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/T3 Code (Nightly).app"), configuration: .init()) { _, error in
            Task { @MainActor in
                self.notice = error?.localizedDescription ?? "Project path copied. In T3 Code, select or add this project: \(repo.path)"
            }
        }
    }
    func quit(_ usage: AppUsage, force: Bool) {
        guard usage.canQuit, let app = usage.application, !app.isTerminated else { notice = "This app is no longer running or cannot be quit here."; return }
        let accepted = force ? app.forceTerminate() : app.terminate()
        notice = accepted ? "\(force ? "Force quit" : "Quit") requested for \(usage.name). It may take a moment to close." : "\(usage.name) did not accept the quit request. You can inspect it in Activity Monitor."
    }
    func reasons(for usage: AppUsage) -> [String] {
        var reasons: [String] = []
        if let start = highCPUStart[usage.id], Date().timeIntervalSince(start) >= 10 {
            reasons.append("Heavy CPU across consecutive samples (10+ seconds)")
        } else if performance.cpu >= 75 && usage.cpu >= 40 {
            reasons.append("High CPU while your Mac’s overall CPU is busy")
        }
        if performance.memoryLevel >= 2 && usage.memoryMB >= 512 {
            reasons.append("Uses " + String(format: "%.1f GB", usage.memoryMB / 1024) + " resident memory while memory pressure is elevated")
        }
        return reasons
    }
    var contributors: [AppUsage] { apps.filter { !reasons(for: $0).isEmpty } }
    func activityMonitor() { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
    private func group(_ rows: [ProcessRow]) -> [AppUsage] {
        let running = NSWorkspace.shared.runningApplications
        let byPID = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })
        let applications = Dictionary(uniqueKeysWithValues: running.map { ($0.processIdentifier, $0) })
        var grouped: [String: AppUsage] = [:]
        for row in rows {
            var app = applications[row.pid]
            var parent = row.parent
            var visited = Set<Int32>()
            while app == nil && parent > 1 && visited.insert(parent).inserted {
                app = applications[parent]
                parent = byPID[parent]?.parent ?? 0
            }
            if app == nil {
                app = running.filter { candidate in
                    guard let path = candidate.bundleURL?.path else { return false }
                    return row.command.hasPrefix(path + "/")
                }.max { ($0.bundleURL?.path.count ?? 0) < ($1.bundleURL?.path.count ?? 0) }
            }
            // macOS may register Chromium/Electron helpers as applications themselves.
            // Attribute those entries to the outer desktop app when it is running.
            if let bundlePath = app?.bundleURL?.path {
                let outerPath: String
                if let range = bundlePath.range(of: ".app/") { outerPath = String(bundlePath[..<range.lowerBound]) + ".app" }
                else { outerPath = bundlePath }
                if let desktop = running.first(where: { $0.bundleURL?.path == outerPath && $0.activationPolicy == .regular }) { app = desktop }
            }
            let key = app.map { "app-\($0.processIdentifier)" } ?? "pid-\(row.pid)"
            if grouped[key] == nil {
                grouped[key] = AppUsage(id: key, name: app?.localizedName ?? row.name, icon: app?.icon, application: app, processes: [])
            }
            grouped[key]?.processes.append(row)
        }
        return grouped.values.sorted { $0.cpu > $1.cpu }
    }
}
