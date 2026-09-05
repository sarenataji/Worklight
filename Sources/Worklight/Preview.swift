import SwiftUI
import AppKit

@MainActor
func renderPreview() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if CommandLine.arguments.contains("--timer") { renderTimerPreview(); return }
    let model = DashboardModel()
    model.repositories = discoverRepositories(root: model.root).map { inspectRepository($0, fetch: false) }
    let sampler = SystemSampler(); _ = sampler.sample(); Thread.sleep(forTimeInterval: 1)
    model.performance = sampler.sample()
    model.history = [model.performance.cpu, model.performance.cpu]
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let views: [(tab: Int, expanded: String?, filename: String)] = [
        (0, nil, "projects-preview.png"),
        (1, nil, "performance-preview.png"),
        (0, model.repositories.first(where: { !$0.files.isEmpty })?.id, "files-preview.png")
    ]
    for appearance in ["dark", "light"] {
    for preview in views {
        let view = NSHostingView(rootView: DashboardView(model: model, initialTab: preview.tab, expandedRepository: preview.expanded, appearanceOverride: appearance))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: DashboardView.width, height: DashboardView.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: directory.appendingPathComponent(appearance + "-" + preview.filename)) }
        window.orderOut(nil)
    }
    }
    print("Rendered dashboard previews in dist/")
}

@MainActor
private func renderTimerPreview() {
    let domain = "Worklight.preview." + UUID().uuidString
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    var store = WorkSessionStore(legacy: ["/SET": 26])
    store.project = "/SET"
    store.pending = WorkSession(project: "/SET", start: Date().addingTimeInterval(-310), end: Date())
    defaults.set(try! JSONEncoder().encode(store), forKey: "workSessions.v2")
    let tracker = WorkTimeTracker(defaults: defaults)
    for scheme in [ColorScheme.dark, .light] {
        let panel = WorkTimeSummary(tracker: tracker, repositories: [Repository(path: "/SET")]).timerPanel
            .background(scheme == .dark ? Color(red: 0.12, green: 0.12, blue: 0.13) : Color.white)
            .environment(\.colorScheme, scheme)
        let view = NSHostingView(rootView: panel)
        let size = view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = view
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "dist/timer-\(scheme == .dark ? "dark" : "light").png"))
        }
        window.orderOut(nil)
    }
}
