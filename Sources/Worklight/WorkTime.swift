import AppKit
import SwiftUI
import CoreGraphics

struct WorkTimeLedger: Codable {
    var seconds: [String: Double] = [:]
    static func display(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        if value >= 3600 { return "\(value / 3600)h \((value % 3600) / 60)m \(value % 60)s" }
        return "\(value / 60)m \(value % 60)s"
    }
}

struct WorkSession: Codable, Identifiable {
    var id = UUID()
    var project: String
    var start: Date
    var end: Date
    var seconds: Double { max(0, end.timeIntervalSince(start)) }
}

/// Each uninterrupted work interval is editable; legacy totals remain untouched.
struct WorkSessionStore: Codable {
    var legacy: [String: Double] = [:]
    var sessions: [WorkSession] = []
    var project: String?
    var currentID: UUID?
    var pending: WorkSession?
    var reason = "Not started"

    var active: Bool { currentID != nil }
    mutating func resume(at now: Date) {
        guard let project, pending == nil, !active else { return }
        let session = WorkSession(project: project, start: now, end: now)
        sessions.append(session); currentID = session.id; reason = "Tracking"
    }
    mutating func pause(_ reason: String) {
        currentID = nil
        self.reason = reason
    }
    mutating func sample(at now: Date, idle: Double) {
        if let interval = pending {
            if now >= interval.end && now.timeIntervalSince(interval.end) <= 15 { pending?.end = now }
            return
        }
        guard let index = sessions.firstIndex(where: { $0.id == currentID }) else { return }
        guard now >= sessions[index].end, now.timeIntervalSince(sessions[index].end) <= 15 else {
            pause("Paused—time gap"); return
        }
        guard idle.isFinite, idle >= 0 else { pause("Paused—activity unavailable"); return }
        // Starting or resuming is explicit activity; ignore idle time before it.
        let sessionIdle = min(idle, now.timeIntervalSince(sessions[index].start))
        if sessionIdle >= 300 {
            let start = now.addingTimeInterval(-sessionIdle)
            sessions[index].end = start
            pending = WorkSession(project: sessions[index].project, start: start, end: now)
            pause("Idle—awaiting review")
        } else {
            sessions[index].end = now
        }
    }
    mutating func resolveIdle(include: Bool, at now: Date) {
        guard let pending else { return }
        if include { sessions.append(pending) }
        self.pending = nil
        resume(at: now)
    }
    func totals() -> [String: Double] {
        var result = legacy
        for session in sessions { result[session.project, default: 0] += session.seconds }
        return result
    }
}

@MainActor
final class WorkTimeTracker: ObservableObject {
    static let shared = WorkTimeTracker()
    @Published private(set) var store = WorkSessionStore()
    @Published private(set) var storageError: String?
    private let defaults: UserDefaults
    private let key = "workSessions.v2"
    private var observers: [NSObjectProtocol] = []
    private var suspended = false
    private var pendingFrozen = false
    private var lastSample = ProcessInfo.processInfo.systemUptime
    private var lastSave = ProcessInfo.processInfo.systemUptime
    var project: String? { store.project }
    var active: Bool { store.active }
    var status: String { store.reason }
    var ledger: WorkTimeLedger { WorkTimeLedger(seconds: store.totals()) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        do {
            if let data = defaults.data(forKey: key) {
                store = try JSONDecoder().decode(WorkSessionStore.self, from: data)
                store.pause(store.pending != nil ? "Idle—awaiting review" : store.project == nil ? "Not started" : "Paused—app restarted")
                pendingFrozen = store.pending != nil
            } else if let data = defaults.data(forKey: "workTimeLedger.v1") {
                store.legacy = try JSONDecoder().decode(WorkTimeLedger.self, from: data).seconds
            }
        } catch { storageError = "Saved work time could not be read. Tracking is disabled to preserve it." }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.sample(); self.suspended = true; self.pendingFrozen = true
                    if self.project != nil { self.store.pause(self.store.pending == nil ? "Paused—sleep or lock" : "Idle—awaiting review") }
                    self.save()
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspended = false; self?.lastSample = ProcessInfo.processInfo.systemUptime }
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
    func start(project: String) {
        guard storageError == nil, store.pending == nil, !suspended else { return }
        sample()
        guard store.pending == nil else { return }
        store.pause("Paused manually"); store.project = project
        pendingFrozen = false; store.resume(at: Date()); lastSample = ProcessInfo.processInfo.systemUptime; save()
    }
    func pause() { sample(); if store.pending == nil { store.pause("Paused manually") }; save() }
    func resume() {
        guard storageError == nil, !suspended else { return }
        pendingFrozen = false; store.resume(at: Date()); lastSample = ProcessInfo.processInfo.systemUptime; save()
    }
    func stop() {
        sample()
        guard store.pending == nil else { return }
        store.pause("Not started"); store.project = nil; save()
    }
    func resolveIdle(include: Bool) {
        guard !suspended else { return }
        sample(); store.resolveIdle(include: include, at: Date()); pendingFrozen = false
        lastSample = ProcessInfo.processInfo.systemUptime; save()
    }
    func sample() {
        guard storageError == nil, !suspended else { return }
        let wasActive = active
        let now = ProcessInfo.processInfo.systemUptime
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        if now - lastSample > 15 || now < lastSample {
            if active { store.pause("Paused—time gap") }
            pendingFrozen = true
        } else if !(store.pending != nil && pendingFrozen) {
            store.sample(at: Date(), idle: idle)
            if store.pending != nil && idle < 300 { pendingFrozen = true }
        }
        lastSample = now
        if now - lastSave >= 30 || wasActive != active { save() }
    }
    func canEdit(_ session: WorkSession) -> Bool {
        session.start.timeIntervalSince1970.isFinite && session.end.timeIntervalSince1970.isFinite &&
        session.end > session.start && session.end <= Date() &&
        !store.sessions.contains { $0.id != session.id && $0.start < session.end && $0.end > session.start } &&
        !(store.pending.map { $0.start < session.end && $0.end > session.start } ?? false)
    }
    func edit(_ session: WorkSession) {
        guard storageError == nil, canEdit(session), session.id != store.currentID,
              let index = store.sessions.firstIndex(where: { $0.id == session.id }) else { return }
        store.sessions[index] = session; save()
    }
    func save() {
        guard storageError == nil else { return }
        if let data = try? JSONEncoder().encode(store) { defaults.set(data, forKey: key) }
        lastSave = ProcessInfo.processInfo.systemUptime
    }
    func seconds(for path: String? = nil, live: Bool = true) -> Double {
        let totals = store.totals()
        let stored = path.map { totals[$0, default: 0] } ?? totals.values.reduce(0, +)
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
                    .help("Project session time, including work across apps")
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
            .popover(isPresented: $expanded) { timerPanel }
    }
    private var stateColor: Color { tracker.store.pending != nil ? .orange : tracker.active ? .green : .secondary }
    var timerPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Project timer", systemImage: "timer").font(.system(size: 11, weight: .semibold))
                Spacer()
                Label(tracker.store.pending != nil ? "Review idle" : tracker.active ? "Tracking" : "Paused",
                      systemImage: tracker.active ? "play.fill" : "pause.fill")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(stateColor)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(stateColor.opacity(0.12), in: Capsule())
                    .help(tracker.status)
            }
            if let error = tracker.storageError { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack(alignment: .firstTextBaseline) {
                Menu {
                    ForEach(repositories) { repo in
                        Button(repo.name) { tracker.start(project: repo.path) }
                    }
                } label: {
                    Text(tracker.project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Choose project")
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
                    .disabled(repositories.isEmpty || tracker.storageError != nil || tracker.store.pending != nil)
                    .help("Start or switch project. Sessions track across all apps.")
                Spacer(minLength: 8)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(WorkTimeLedger.display(tracker.seconds(for: tracker.project)))
                        .font(.system(size: 23, weight: .semibold).monospacedDigit()).foregroundStyle(stateColor)
                        .fixedSize()
                }
            }
            if let pending = tracker.store.pending {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Count \(WorkTimeLedger.display(pending.seconds)) idle?", systemImage: "clock.badge.questionmark")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                    HStack(spacing: 6) {
                        Button { tracker.resolveIdle(include: true) } label: {
                            Label("Count", systemImage: "checkmark").frame(maxWidth: .infinity)
                        }.tint(.green)
                        Button { tracker.resolveIdle(include: false) } label: {
                            Label("Exclude", systemImage: "xmark").frame(maxWidth: .infinity)
                        }.tint(.orange)
                    }.buttonStyle(.borderedProminent).controlSize(.small)
                    Text("Either choice resumes tracking.").font(.system(size: 9)).foregroundStyle(.secondary)
                }.padding(9).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            } else if tracker.project != nil {
                HStack(spacing: 6) {
                    Button {
                        if tracker.active { tracker.pause() } else { tracker.resume() }
                    } label: {
                        Label(tracker.active ? "Pause" : "Resume", systemImage: tracker.active ? "pause.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }.tint(tracker.active ? .orange : .green)
                    Button { tracker.stop() } label: {
                        Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }.tint(.pink)
                }.buttonStyle(.borderedProminent).controlSize(.small)
                if !tracker.active { Text(tracker.status).font(.system(size: 9)).foregroundStyle(.secondary) }
            }
            Divider()
            HStack {
                SessionHistory(tracker: tracker, repositories: repositories).buttonStyle(.plain).foregroundStyle(.cyan)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("Total \(WorkTimeLedger.display(tracker.seconds()))").monospacedDigit()
                }.font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if timeShares.count > 1 {
                ForEach(Array(timeShares.enumerated()), id: \.offset) { index, share in
                    HStack(spacing: 5) {
                        Circle().fill(shareColor(index)).frame(width: 5, height: 5)
                        Text(share.name).lineLimit(1)
                        Spacer()
                        Text(WorkTimeLedger.display(share.seconds)).monospacedDigit()
                    }.font(.system(size: 9)).help(share.path)
                }
            }
        }.padding(12).frame(width: 280)
            .help("Saved locally. Tracks across apps; reviews idle after 5 minutes. Sleep and lock pause tracking.")
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
            if tracker.project == path {
                Text(tracker.status).font(.system(size: 9))
                if tracker.store.pending == nil {
                    HStack {
                        Button(tracker.active ? "Pause" : "Resume") {
                            if tracker.active { tracker.pause() } else { tracker.resume() }
                        }
                        Button("Stop") { tracker.stop() }
                    }
                } else { Text("Review idle time in Work time above.").font(.system(size: 9)) }
            } else {
                Button("Start project session") { tracker.start(project: path) }
                    .disabled(tracker.storageError != nil || tracker.store.pending != nil)
            }
            Text("Session follows you across apps.").font(.system(size: 8)).foregroundStyle(.secondary)
        }.buttonStyle(.plain)
    }
}

struct SessionHistory: View {
    @ObservedObject var tracker: WorkTimeTracker
    let repositories: [Repository]
    @State private var showing = false
    var body: some View {
        Button("History…") { showing = true }
            .font(.system(size: 11))
            .sheet(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Session history").font(.headline)
                    Text("Pause to edit the current interval. Earlier totals have no session details.")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(tracker.store.sessions.reversed()) { session in
                                SessionEditor(tracker: tracker, repositories: repositories, session: session)
                                    .disabled(session.id == tracker.store.currentID)
                                Divider()
                            }
                        }
                    }
                    Button("Done") { showing = false }
                }.padding(20).frame(width: 520, height: 440)
            }
    }
}

struct SessionEditor: View {
    @ObservedObject var tracker: WorkTimeTracker
    let repositories: [Repository]
    let session: WorkSession
    @State private var draft: WorkSession
    init(tracker: WorkTimeTracker, repositories: [Repository], session: WorkSession) {
        self.tracker = tracker; self.repositories = repositories; self.session = session
        _draft = State(initialValue: session)
    }
    private var valid: Bool { tracker.canEdit(draft) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Project", selection: $draft.project) {
                ForEach(Array(Set(repositories.map(\.path) + [session.project])).sorted(), id: \.self) { path in
                    Text(URL(fileURLWithPath: path).lastPathComponent).tag(path)
                }
            }
            DatePicker("Start", selection: $draft.start)
            DatePicker("End", selection: $draft.end)
            HStack {
                Text(WorkTimeLedger.display(session.seconds)).font(.caption)
                Spacer()
                Button("Save changes") { tracker.edit(draft) }.disabled(!valid)
            }
            if !valid { Text("Use a past interval with end after start, without overlapping another session.").font(.caption) }
        }.onChange(of: session.end) { _, value in draft.end = value }
    }
}
