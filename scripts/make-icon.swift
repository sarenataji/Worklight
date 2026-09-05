import AppKit
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
        NSColor(calibratedRed: 0.035, green: 0.035, blue: 0.035, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 210, yRadius: 210).fill()
        NSColor(calibratedRed: 0.875, green: 1.0, blue: 0.0, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 362, y: 362, width: 300, height: 300)).fill()
        NSColor(calibratedRed: 0.875, green: 1.0, blue: 0.0, alpha: 1).setStroke()
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4
            let p = NSBezierPath(); p.lineWidth = 36; p.lineCapStyle = .round
            p.move(to: NSPoint(x: 512 + cos(angle) * 235, y: 512 + sin(angle) * 235))
            p.line(to: NSPoint(x: 512 + cos(angle) * 300, y: 512 + sin(angle) * 300)); p.stroke()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
