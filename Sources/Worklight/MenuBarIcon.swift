import AppKit
import SwiftUI

struct WaveConfiguration: Equatable {
    let cpu: Double
    let reduceMotion: Bool
}

@MainActor
final class MenuBarWaveAnimator: ObservableObject {
    @Published private(set) var image = MenuBarIcon.wave(cpu: 0)

    func animate(_ configuration: WaveConfiguration) async {
        let cpu = configuration.cpu
        image = MenuBarIcon.wave(cpu: cpu)
        guard !configuration.reduceMotion, cpu >= 20 else { return }
        var frame = 0
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 125_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            frame = (frame + 1) % 20
            image = MenuBarIcon.wave(cpu: cpu, phase: Double(frame) / 20 * 2 * .pi)
        }
    }
}

enum MenuBarIcon {
    /// Draw a tapered wave as a template so macOS supplies its foreground color.
    static func wave(cpu: Double, phase: Double = 0) -> NSImage {
        let load = cpu.isFinite ? min(100, max(0, cpu)) / 100 : 0
        let amplitude = 1.2 + 5.3 * load
        let image = NSImage(size: NSSize(width: 26, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            for step in 0...96 {
                let t = Double(step) / 96
                let envelope = pow(sin(.pi * t), 0.8)
                let point = NSPoint(x: 1 + 24 * t,
                                    y: 9 + amplitude * envelope * sin(t * 6 * .pi - phase))
                if step == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Worklight CPU waveform"
        return image
    }
}
