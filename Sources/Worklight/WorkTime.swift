import AppKit
import SwiftUI
import CoreGraphics

struct WorkTimeLedger: Codable {
    var seconds: [String: Double] = [:]
    mutating func credit(project: String?, elapsed: Double, wasActive: Bool, isActive: Bool) {
        // Reject sleep, clock changes, delayed samples and uncertain transitions.
        guard let project, wasActive, isActive, elapsed > 0, elapsed <= 10 else { return }
        seconds[project, default: 0] += elapsed
    }
    static func shouldCount(selected: Bool, focused: Bool, running: Bool, suspended: Bool, idle: Double) -> Bool {
        selected && focused && running && !suspended && idle.isFinite && idle >= 0 && idle < 60
    }
    static func display(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        if value >= 3600 { return "\(value / 3600)h \((value % 3600) / 60)m \(value % 60)s" }
        return "\(value / 60)m \(value % 60)s"
    }
}

/// Explicit project/app sessions: no guessing from background agent activity.
@MainActor
final class WorkTimeTracker: ObservableObject {
    static let shared = WorkTimeTracker()
    @Published private(set) var ledger: WorkTimeLedger
    @Published private(set) var project: String?
    @Published private(set) var appName = ""
    @Published private(set) var active = false
    @Published private(set) var storageError: String?
    private var appPID: pid_t?
    private var lastExternalPID: pid_t?
    private var lastSample = ProcessInfo.processInfo.systemUptime
    private var lastSave = ProcessInfo.processInfo.systemUptime
    private var suspended = false
    private var observers: [NSObjectProtocol] = []
    private let defaults: UserDefaults
    private let key = "workTimeLedger.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key) {
            do { ledger = try JSONDecoder().decode(WorkTimeLedger.self, from: data) }
            catch { ledger = WorkTimeLedger(); storageError = "Saved work time could not be read. Tracking is disabled to preserve it." }
        } else { ledger = WorkTimeLedger() }
        lastExternalPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspended = true; self?.sample(); self?.save() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspended = false; self?.active = false; self?.lastSample = ProcessInfo.processInfo.systemUptime }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample(); self?.save() }
        })
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                if self.project != nil { self.sample() }
            }
        }
    }
    var availableApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
    func start(project: String, app: NSRunningApplication) {
        guard storageError == nil, !app.isTerminated else { return }
        sample(); save()
        self.project = project
        appPID = app.processIdentifier
        appName = app.localizedName ?? "Selected app"
        active = false
        lastSample = ProcessInfo.processInfo.systemUptime
        sample()
    }
    func stop() {
        sample(); save()
        project = nil; appPID = nil; active = false
    }
    func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Checking Worklight's own popup keeps the last external app association.
        if foreground != ProcessInfo.processInfo.processIdentifier { lastExternalPID = foreground }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
        let alive = appPID.flatMap { NSRunningApplication(processIdentifier: $0) }?.isTerminated == false
        let eligible = WorkTimeLedger.shouldCount(selected: project != nil, focused: appPID == lastExternalPID, running: alive, suspended: suspended, idle: idle)
        ledger.credit(project: project, elapsed: now - lastSample, wasActive: active, isActive: eligible)
        active = eligible
        lastSample = now
        if now - lastSave >= 30 { save() }
        if project != nil && !alive { save(); project = nil; appPID = nil; active = false }
    }
    func save() {
        guard storageError == nil else { return }
        if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: key) }
        lastSave = ProcessInfo.processInfo.systemUptime
    }
    func seconds(for path: String? = nil, live: Bool = true) -> Double {
        let stored = path.map { ledger.seconds[$0, default: 0] } ?? ledger.seconds.values.reduce(0, +)
        // UI-only interpolation; persistent accounting remains in five-second samples.
        let extra = live && active && (path == nil || path == project) ? min(5, max(0, ProcessInfo.processInfo.systemUptime - lastSample)) : 0
        return stored + extra
    }
}

struct ProjectWorkTime: View {
    @ObservedObject var tracker: WorkTimeTracker
    let path: String
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if tracker.ledger.seconds[path] != nil || tracker.project == path {
                Text("◷ " + WorkTimeLedger.display(tracker.seconds(for: path)))
                    .font(.system(size: 8).monospacedDigit()).foregroundStyle(.secondary)
                    .help("Estimated active work time since tracking began; idle and background AI time excluded")
            }
        }
    }
}

struct WorkTimeSummary: View {
    @ObservedObject var tracker: WorkTimeTracker
    let repositories: [Repository]
    @State private var expanded = false
    @Environment(\.colorScheme) private var scheme
    private var accent: Color { scheme == .dark ? Color(red: 0.875, green: 1, blue: 0) : Color(red: 0.38, green: 0.42, blue: 0.17) }
    var body: some View {
        Button { expanded.toggle() } label: {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let entries = timeShares
                let total = tracker.seconds()
                VStack(spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("Work time").font(.system(size: 8)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text(WorkTimeLedger.display(total))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    GeometryReader { geometry in
                        HStack(spacing: 2) {
                            ForEach(entries.indices, id: \.self) { index in
                                Capsule().fill(shareColor(index))
                                    .frame(width: max(0, geometry.size.width - CGFloat(max(0, entries.count - 1)) * 2) * entries[index].seconds / max(1, total))
                            }
                        }
                    }.frame(height: 3).accessibilityHidden(true)
                }
            }
        }.buttonStyle(.plain).frame(width: 130)
            .help("Total active work time across projects. Click to track a project or view the breakdown.")
            .popover(isPresented: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Project timer").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(tracker.project == nil ? "Not started" : tracker.active ? "Tracking" : "Paused")
                            .font(.system(size: 10)).foregroundStyle(tracker.active ? accent : .secondary)
                    }
                    if let error = tracker.storageError { Text(error).font(.caption) }
                    if let project = tracker.project {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(URL(fileURLWithPath: project).lastPathComponent).font(.system(size: 15, weight: .semibold))
                                .lineLimit(2).help(project)
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(WorkTimeLedger.display(tracker.seconds(for: project)))
                                    .font(.system(size: 22, weight: .medium).monospacedDigit())
                            }
                        }
                        info("Using", tracker.appName)
                    }
                    info("Detection", "Manual selection")
                    Divider()
                    Menu {
                        ForEach(repositories) { repo in
                            Menu(repo.name) {
                                ForEach(tracker.availableApps, id: \.processIdentifier) { app in
                                    Button(app.localizedName ?? "App") { tracker.start(project: repo.path, app: app) }
                                }
                            }
                        }
                    } label: {
                        Label(tracker.project == nil ? "Choose project and app…" : "Switch project or app…", systemImage: "folder")
                    }.menuStyle(.borderlessButton).disabled(repositories.isEmpty || tracker.storageError != nil)
                    if tracker.project != nil {
                        Button("Stop tracking") { tracker.stop() }.buttonStyle(.plain).font(.system(size: 11))
                    }
                    Text("Switch here when you change projects in the same app. Pauses when idle or using another app.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("All projects")
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(WorkTimeLedger.display(tracker.seconds())).monospacedDigit()
                        }
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                    if !timeShares.isEmpty {
                        ForEach(Array(timeShares.enumerated()), id: \.offset) { index, share in
                            HStack(spacing: 5) {
                                Circle().fill(shareColor(index)).frame(width: 4, height: 4)
                                Text(share.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(WorkTimeLedger.display(share.seconds)).monospacedDigit()
                            }.font(.system(size: 9)).help(share.path)
                        }
                    }
                    Text("Saved locally · background AI time excluded")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }.padding(16).frame(width: 275)
            }
    }
    private var timeShares: [(name: String, path: String, seconds: Double)] {
        var paths = Set(tracker.ledger.seconds.keys)
        if let project = tracker.project { paths.insert(project) }
        let entries = paths.sorted().map { path in
            (name: URL(fileURLWithPath: path).lastPathComponent, path: path, seconds: tracker.seconds(for: path))
        }.filter { $0.seconds > 0 }
        if entries.count <= 5 { return entries }
        return Array(entries.prefix(4)) + [(name: "Other projects", path: "Remaining tracked projects", seconds: entries.dropFirst(4).reduce(0) { $0 + $1.seconds })]
    }
    private func shareColor(_ index: Int) -> Color {
        let dark: [Color] = [Color(red: 0, green: 0.94, blue: 0.67), Color(red: 0.68, green: 0.36, blue: 1), Color(red: 1, green: 0.16, blue: 0.66), Color(red: 0.29, green: 0.81, blue: 1), accent]
        let light: [Color] = [.green, .purple, .pink, .blue, accent]
        return (scheme == .dark ? dark : light)[index % 5]
    }
    private func info(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).lineLimit(1) }
            .font(.system(size: 10))
    }
}

struct ProjectTimeControls: View {
    @ObservedObject var tracker: WorkTimeTracker
    let path: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Menu("Track time with…") {
                    ForEach(tracker.availableApps, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? "App") { tracker.start(project: path, app: app) }
                    }
                }.menuStyle(.borderlessButton).fixedSize().disabled(tracker.storageError != nil)
                if tracker.project == path {
                    Button("Stop") { tracker.stop() }.buttonStyle(.plain)
                }
            }
            if tracker.project == path { Text("\(tracker.active ? "Tracking" : "Paused") · \(tracker.appName)").font(.system(size: 9)) }
            Text("Select this project again when switching projects in the same app.")
                .font(.system(size: 8)).foregroundStyle(.secondary)
        }
    }
}
