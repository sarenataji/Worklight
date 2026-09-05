import SwiftUI
import AppKit

@MainActor
func renderPreview() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let model = DashboardModel()
    model.repositories = discoverRepositories(root: model.root).map { inspectRepository($0, fetch: false) }
    let sampler = SystemSampler(); _ = sampler.sample(); Thread.sleep(forTimeInterval: 1)
    model.performance = sampler.sample()
    model.history = [model.performance.cpu, model.performance.cpu]
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for tab in 0...1 {
        let view = NSHostingView(rootView: DashboardView(model: model, initialTab: tab))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: directory.appendingPathComponent(tab == 0 ? "projects-preview.png" : "performance-preview.png")) }
        window.orderOut(nil)
    }
    print("Rendered dashboard previews in dist/")
}
