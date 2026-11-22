import AppKit
// iPhone icon: the same record on wood as the Mac icon, full-bleed (iOS rounds the corners itself).
let n: CGFloat = 1024
let cg = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
func disc(_ c: NSPoint, _ r: CGFloat) -> NSBezierPath { NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }
NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.15, blue: 0.09, alpha: 1), ending: NSColor(srgbRed: 0.47, green: 0.30, blue: 0.18, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: n, height: n), angle: 90)
let c = NSPoint(x: n * 0.45, y: n * 0.47), r = n * 0.355
NSColor(white: 0.06, alpha: 1).setFill(); disc(c, r).fill()
for i in 0..<7 { let g = disc(c, r * (0.5 + 0.065 * CGFloat(i))); g.lineWidth = n * 0.004; NSColor(white: 1, alpha: 0.09).setStroke(); g.stroke() }
NSColor(srgbRed: 0.96, green: 0.62, blue: 0.27, alpha: 1).setFill(); disc(c, r * 0.36).fill()
NSColor(white: 0.1, alpha: 1).setFill(); disc(c, n * 0.018).fill()
let arm = NSBezierPath()
arm.move(to: NSPoint(x: n * 0.85, y: n * 0.85)); arm.line(to: NSPoint(x: n * 0.825, y: n * 0.41)); arm.line(to: NSPoint(x: n * 0.66, y: n * 0.27))
arm.lineWidth = n * 0.04; arm.lineCapStyle = .round; arm.lineJoinStyle = .round
NSColor(white: 0.9, alpha: 1).setStroke(); arm.stroke()
NSColor(white: 0.75, alpha: 1).setFill(); disc(NSPoint(x: n * 0.85, y: n * 0.85), n * 0.07).fill()
try! NSBitmapImageRep(cgImage: cg.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
