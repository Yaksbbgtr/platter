import AppKit
// Platter icon: a dark tile holding a vinyl record with a warm label and a silver tonearm.
let folder = CommandLine.arguments[1]
try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let n = CGFloat(size)
    let tile = NSBezierPath(roundedRect: NSRect(x: n * 0.08, y: n * 0.08, width: n * 0.84, height: n * 0.84), xRadius: n * 0.19, yRadius: n * 0.19)
    NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.15, blue: 0.09, alpha: 1), ending: NSColor(srgbRed: 0.47, green: 0.30, blue: 0.18, alpha: 1))!.draw(in: tile, angle: 90)
    tile.addClip()
    let c = NSPoint(x: n * 0.45, y: n * 0.47), r = n * 0.3
    NSColor(white: 0.06, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
    if size >= 64 {
        for i in 0..<7 {
            let rr = r * (0.5 + 0.065 * CGFloat(i))
            let g = NSBezierPath(ovalIn: NSRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
            g.lineWidth = max(1, n * 0.004); NSColor(white: 1, alpha: 0.09).setStroke(); g.stroke()
        }
    }
    let lr = r * 0.36
    NSColor(srgbRed: 0.96, green: 0.62, blue: 0.27, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - lr, y: c.y - lr, width: lr * 2, height: lr * 2)).fill()
    NSColor(white: 0.1, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - n * 0.015, y: c.y - n * 0.015, width: n * 0.03, height: n * 0.03)).fill()
    let arm = NSBezierPath()
    arm.move(to: NSPoint(x: n * 0.78, y: n * 0.8)); arm.line(to: NSPoint(x: n * 0.76, y: n * 0.42)); arm.line(to: NSPoint(x: n * 0.62, y: n * 0.3))
    arm.lineWidth = n * 0.035; arm.lineCapStyle = .round; arm.lineJoinStyle = .round
    NSColor(white: 0.9, alpha: 1).setStroke(); arm.stroke()
    NSColor(white: 0.75, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: n * 0.72, y: n * 0.74, width: n * 0.12, height: n * 0.12)).fill()
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    let name = size == 1024 ? "icon_512x512@2x.png" : "icon_\(size)x\(size).png"
    if size != 64 { try! data.write(to: URL(fileURLWithPath: folder + "/" + name)) }
    if [32, 64, 256, 512].contains(size) { try! data.write(to: URL(fileURLWithPath: folder + "/icon_\(size / 2)x\(size / 2)@2x.png")) }
}
