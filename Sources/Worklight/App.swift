import SwiftUI
import AppKit

@main
struct WorklightApp: App {
    @StateObject private var model = DashboardModel()
    @StateObject private var waveAnimator = MenuBarWaveAnimator()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some Scene {
        MenuBarExtra {
            DashboardView(model: model)
        } label: {
            Label {
                Text(model.incoming > 0 ? "↓\(model.incoming) · \(Int(model.performance.cpu))%" : "\(Int(model.performance.cpu))%")
            } icon: {
                Image(nsImage: waveAnimator.image)
            }
                .task { model.start() }
                .task(id: WaveConfiguration(cpu: model.performance.cpu, reduceMotion: reduceMotion)) {
                    await waveAnimator.animate(WaveConfiguration(cpu: model.performance.cpu, reduceMotion: reduceMotion))
                }
        }.menuBarExtraStyle(.window)
        Window("Worklight", id: "dashboard") {
            DashboardView(model: model)
        }.windowResizability(.contentSize).defaultPosition(.center)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
    init() {
        if CommandLine.arguments.contains("--render-preview") { renderPreview(); exit(0) }
        if CommandLine.arguments.contains("--self-test") { SelfTests.run(); exit(0) }
        if CommandLine.arguments.contains("--diagnose") {
            let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/apps").path
            for path in discoverRepositories(root: root) {
                let repo = inspectRepository(path, fetch: false)
                print("\(repo.name): \(repo.headline), branch=\(repo.branch), incoming=\(repo.behind), outgoing=\(repo.ahead), files=\(repo.changed), error=\(repo.error ?? "none")")
            }
            let sampler = SystemSampler(); _ = sampler.sample(); Thread.sleep(forTimeInterval: 1)
            let sample = sampler.sample()
            print("CPU=\(Int(sample.cpu))%, memoryLevel=\(sample.memoryLevel), swapGB=\(sample.swapGB), processes=\(sample.processes.count)")
            exit(sample.error == nil ? 0 : 1)
        }
    }
}
