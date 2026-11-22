// SPDX-License-Identifier: GPL-3.0-or-later
// Pieces shared by the Platter app and its WidgetKit widget: skins, colours, turntable geometry,
// the tonearm and the plinth's wood grain, plus the now-playing state file the app writes for the widget.

import SwiftUI
import WidgetKit
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
#endif

extension Image {
    init(platform image: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}

func rgbColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> PlatformColor {
    #if os(macOS)
    return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    #else
    return UIColor(red: r, green: g, blue: b, alpha: 1)
    #endif
}

enum Skin: String, CaseIterable {
    case walnut, midnight, arctic, album, custom
    var title: String {
        switch self {
        case .walnut: return "Walnut"
        case .midnight: return "Midnight"
        case .arctic: return "Arctic"
        case .album: return "Album Colors"
        case .custom: return "My Color"
        }
    }
}

func averageColor(_ image: PlatformImage) -> PlatformColor? {
    #if os(macOS)
    let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    #else
    let source = image.cgImage
    #endif
    guard let cg = source else { return nil }
    var px = [UInt8](repeating: 0, count: 4)
    let made: Bool = px.withUnsafeMutableBytes { buf in
        guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return true
    }
    guard made else { return nil }
    return rgbColor(CGFloat(px[0]) / 255, CGFloat(px[1]) / 255, CGFloat(px[2]) / 255)
}

extension PlatformColor {
    func hsb(s: (CGFloat) -> CGFloat = { $0 }, b: (CGFloat) -> CGFloat = { $0 }) -> PlatformColor {
        #if os(macOS)
        let c = usingColorSpace(.sRGB) ?? self
        #else
        let c = self
        #endif
        var h: CGFloat = 0, sa: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &sa, brightness: &br, alpha: &a)
        return PlatformColor(hue: h, saturation: min(1, max(0, s(sa))), brightness: min(1, max(0, b(br))), alpha: a)
    }
}

// MARK: - Look

struct Palette {
    var top: Color, bottom: Color, text: Color, secondary: Color, accent: Color, button: Color, track: Color
    var wood = false
    var rimLight: Color = Color(white: 0.86), rimDark: Color = Color(white: 0.45)
    /// Desktop widgets in monochrome / "clear" mode (another app in front, or that widget style chosen):
    /// macOS paints every view as a white silhouette of its opacity, so the deck is drawn with
    /// translucent whites instead of solid colours, and without shadows (which would glow).
    var mono = false
    // Customizable parts (see Style).
    var style = Style()
    var shine = Color.white                         // the bright edge of the metal
    var vinylLight = Color(white: 0.09), vinylDark = Color(white: 0.04)
    var groove = Color.white                        // dark grooves on a light record
    var gap = 0.75                                  // how dark the gaps between tracks are
    var customPlayIcon: Color?
    /// Light text on a dark plinth?
    var dark: Bool { wood || darkPlinth }
    var darkPlinth = true

    var labelRatio: CGFloat { Deck.labelRadius / Deck.radius * style.labelSize }
    func font(_ size: CGFloat, _ weight: Font.Weight) -> Font { style.font(size * style.textSize, weight) }

    static let monochrome = Palette(top: .clear, bottom: .clear, text: .white, secondary: .white.opacity(0.6), accent: .white,
                                    button: .white.opacity(0.16), track: .white.opacity(0.2),
                                    rimLight: .white.opacity(0.55), rimDark: .white.opacity(0.3), mono: true)

    var shadow: Color { mono ? .clear : .black }
    var playFill: Color { mono ? .white.opacity(0.28) : accent }
    var playIcon: Color { mono ? .white : customPlayIcon ?? (dark ? .black.opacity(0.8) : .white) }

    static func monochrome(_ style: Style) -> Palette { var p = monochrome; p.style = style; return p }

    static func make(_ skin: Skin, art: PlatformColor?, style: Style = Style()) -> Palette {
        var p = base(skin, art: art, style: style)
        p.style = style
        if let c = PlatformColor(hex: style.accent) {
            p.accent = Color(c)
            p.customPlayIcon = c.luminance > 0.55 ? .black.opacity(0.8) : .white
        }
        if let c = PlatformColor(hex: style.text) { p.text = Color(c); p.secondary = Color(c).opacity(0.62) }
        if let c = PlatformColor(hex: style.vinyl) {
            p.vinylLight = Color(c.hsb(b: { min(1, $0 * 1.08) }))
            p.vinylDark = Color(c.hsb(b: { $0 * 0.72 }))
            p.gap = c.luminance > 0.2 ? 0.28 : 0.7
            if c.luminance > 0.55 { p.groove = .black }
        }
        if let c = PlatformColor(hex: style.metal) {
            p.rimLight = Color(c.hsb(b: { min(1, $0 * 1.15) }))
            p.rimDark = Color(c.hsb(b: { $0 * 0.5 }))
            p.shine = Color(c.hsb(s: { $0 * 0.4 }, b: { min(1, $0 * 1.2 + 0.2) }))
        }
        return p
    }

    private static func base(_ skin: Skin, art: PlatformColor?, style: Style) -> Palette {
        let artAccent = art.map { Color($0.hsb(s: { max($0, 0.45) }, b: { min(max($0, 0.7), 0.95) })) }
        func hex(_ v: UInt32) -> Color {
            Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
        }
        switch skin {
        case .walnut:
            let cream = hex(0xF4E6D0)
            return Palette(top: hex(0x74492C), bottom: hex(0x3A2214), text: cream, secondary: cream.opacity(0.62),
                           accent: artAccent ?? hex(0xF0A54A), button: cream.opacity(0.13), track: Color.black.opacity(0.32), wood: true)
        case .midnight:
            return Palette(top: hex(0x2A2A30), bottom: hex(0x101013), text: .white, secondary: .white.opacity(0.55),
                           accent: artAccent ?? hex(0xFF5A4E), button: .white.opacity(0.09), track: .white.opacity(0.12),
                           rimLight: Color(white: 0.55), rimDark: Color(white: 0.2))
        case .arctic:
            let ink = hex(0x24221F)
            return Palette(top: hex(0xF7F5F1), bottom: hex(0xDAD5CD), text: ink, secondary: ink.opacity(0.55),
                           accent: art.map { Color($0.hsb(s: { max($0, 0.5) }, b: { min(max($0, 0.55), 0.8) })) } ?? hex(0xE2683C),
                           button: Color.black.opacity(0.07), track: Color.black.opacity(0.1), darkPlinth: false)
        case .custom:
            let c = PlatformColor(hex: style.plinth) ?? rgbColor(0.18, 0.36, 0.38)
            let dark = c.luminance < 0.6
            let ink = dark ? Color.white : Color(white: 0.13)
            return Palette(top: Color(c.hsb(b: { min(1, $0 * 1.1) })), bottom: Color(c.hsb(b: { $0 * (dark ? 0.58 : 0.86) })),
                           text: ink, secondary: ink.opacity(0.62), accent: artAccent ?? (dark ? hex(0xF0A54A) : hex(0xE2683C)),
                           button: ink.opacity(0.12), track: Color.black.opacity(dark ? 0.3 : 0.12), darkPlinth: dark)
        case .album:
            let base = art ?? rgbColor(0.33, 0.38, 0.78)
            return Palette(top: Color(base.hsb(s: { min($0 * 1.1, 0.75) }, b: { min(max($0 * 0.75, 0.32), 0.6) })),
                           bottom: Color(base.hsb(s: { min($0 * 1.1, 0.8) }, b: { min(max($0 * 0.38, 0.12), 0.28) })),
                           text: .white, secondary: .white.opacity(0.62),
                           accent: Color(base.hsb(s: { min($0, 0.35) }, b: { _ in 1 })), button: .white.opacity(0.13),
                           track: Color.black.opacity(0.28), rimLight: Color(white: 0.7), rimDark: Color(white: 0.3))
        }
    }
}

// MARK: - Turntable geometry (deck coordinates, 300 × 250)

enum Deck {
    static let size = CGSize(width: 300, height: 250)
    static let center = CGPoint(x: 128, y: 124)
    static let radius: CGFloat = 104
    static let pivot = CGPoint(x: 260, y: 44)
    static let armLength: CGFloat = 172
    static let restAngle: Double = -2
    static let labelRadius: CGFloat = 38

    /// Stylus position for an arm rotated clockwise by `deg` from pointing straight down.
    static func stylus(_ deg: Double) -> CGPoint {
        let t = deg * .pi / 180
        return CGPoint(x: pivot.x - armLength * sin(t), y: pivot.y + armLength * cos(t))
    }
    /// The first arm angle (sweeping in from rest) whose stylus sits `r` from the spindle.
    static func angle(forGroove r: CGFloat) -> Double {
        var deg = 0.0
        while deg < 90 {
            let s = stylus(deg)
            if hypot(s.x - center.x, s.y - center.y) <= r { return deg }
            deg += 0.05
        }
        return deg
    }
    static let outerGroove = angle(forGroove: radius * 0.94)
    static let innerGroove = angle(forGroove: radius * 0.46)
}

struct TonearmView: View {
    let palette: Palette

    var body: some View {
        let p = Deck.pivot, L = Deck.armLength
        let metal = LinearGradient(colors: [palette.rimLight, palette.shine, palette.rimDark], startPoint: .leading, endPoint: .trailing)
        ZStack(alignment: .topLeading) {
            // counterweight
            RoundedRectangle(cornerRadius: 3).fill(LinearGradient(colors: [Color(white: 0.35), Color(white: 0.12), Color(white: 0.3)],
                                                                  startPoint: .leading, endPoint: .trailing))
                .frame(width: 17, height: 24).offset(x: p.x - 8.5, y: p.y - 40)
            // arm tube
            Capsule().fill(metal).frame(width: 4.5, height: L - 18).offset(x: p.x - 2.25, y: p.y - 14)
            // headshell + cartridge
            RoundedRectangle(cornerRadius: 2.5).fill(metal).frame(width: 12, height: 26).offset(x: p.x - 6, y: p.y + L - 30)
            RoundedRectangle(cornerRadius: 1.5).fill(Color(white: 0.12)).frame(width: 9, height: 12).offset(x: p.x - 4.5, y: p.y + L - 14)
            RoundedRectangle(cornerRadius: 1).fill(palette.rimLight).frame(width: 3, height: 9).offset(x: p.x + 6, y: p.y + L - 30)
            // pivot cap
            Circle().fill(RadialGradient(colors: [palette.shine, palette.rimDark], center: .topLeading, startRadius: 1, endRadius: 14))
                .frame(width: 14, height: 14).offset(x: p.x - 7, y: p.y - 7)
        }
        .frame(width: Deck.size.width, height: Deck.size.height, alignment: .topLeading)
    }
}

/// Wavy grain lines for the Walnut plinth (plain shapes, so it also renders inside the widget).
struct WoodGrain: View {
    var body: some View {
        ZStack {
            GrainLines(dark: true).stroke(Color.black.opacity(0.16), lineWidth: 1.3)
            GrainLines(dark: false).stroke(Color.white.opacity(0.05), lineWidth: 0.9)
        }
    }
}

struct GrainLines: Shape {
    let dark: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        var rng = SeededRandom(seed: 7)
        let count = max(12, Int(rect.height / 8.5))
        for i in 0..<count {
            let y0 = CGFloat(i) / CGFloat(count) * rect.height + CGFloat(rng.next()) * 6
            let amp = 2 + CGFloat(rng.next()) * 5, freq = 0.008 + CGFloat(rng.next()) * 0.012, phase = CGFloat(rng.next()) * 6
            guard (rng.next() > 0.45) == dark else { continue }
            p.move(to: CGPoint(x: -4, y: y0))
            var x: CGFloat = -4
            while x <= rect.width + 4 { x += 6; p.addLine(to: CGPoint(x: x, y: y0 + sin(x * freq + phase) * amp)) }
        }
        return p
    }
}

struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}


func formatTime(_ t: Double) -> String {
    guard t.isFinite else { return "–:––" }
    let s = Int(max(0, t).rounded(.down))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Record built from plain shapes (the widget can't run a Canvas every frame)

struct DiscView: View {
    let artwork: PlatformImage?
    let palette: Palette

    var body: some View {
        GeometryReader { g in
            let R = min(g.size.width, g.size.height) / 2
            let labelR = R * palette.labelRatio
            let inner = labelR * 1.12, outer = R * 0.975
            ZStack {
                if palette.mono {
                    Circle().fill(Color.white.opacity(0.1))
                } else {
                    Circle().fill(RadialGradient(colors: [palette.vinylLight, palette.vinylDark], center: .center,
                                                 startRadius: labelR, endRadius: R))
                }
                ForEach(0..<20, id: \.self) { i in
                    let r = inner + (outer - inner) * CGFloat(i) / 19
                    Circle().stroke(palette.groove.opacity(i % 3 == 0 ? 0.065 : 0.04), lineWidth: 0.7).frame(width: r * 2, height: r * 2)
                }
                ForEach([0.18, 0.39, 0.57, 0.76] as [CGFloat], id: \.self) { f in
                    let r = inner + (outer - inner) * f
                    Circle().stroke(palette.mono ? Color.white.opacity(0.12) : Color.black.opacity(palette.gap), lineWidth: 1.8).frame(width: r * 2, height: r * 2)
                }
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 1).padding(0.8)
                Circle().fill(Color.white.opacity(0.04)).frame(width: R * 0.1, height: R * 0.1).offset(y: -R * 0.68)
                Group {
                    if let artwork {
                        FullColorImage(image: artwork)
                    } else {
                        ZStack {
                            Circle().fill(palette.mono ? Color.white.opacity(0.35) : palette.accent)
                            Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.7).padding(labelR * 0.18)
                            Text("PLATTER").font(palette.style.font(labelR * 0.26, .heavy))
                                .foregroundColor(.black.opacity(0.7)).offset(y: -labelR * 0.45)
                            Text("33⅓ RPM").font(palette.style.font(labelR * 0.16, .semibold))
                                .foregroundColor(.black.opacity(0.55)).offset(y: labelR * 0.5)
                        }
                    }
                }
                .frame(width: labelR * 2, height: labelR * 2)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.black.opacity(0.45), lineWidth: 1.2))
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

/// The static reflection on the vinyl (it stays put while the disc turns) plus the spindle.
struct SheenView: View {
    let palette: Palette
    var body: some View {
        GeometryReader { g in
            let R = min(g.size.width, g.size.height) / 2
            let labelR = R * palette.labelRatio
            let clear = Color.white.opacity(0)
            ZStack {
                AngularGradient(gradient: Gradient(stops: [
                    .init(color: clear, location: 0), .init(color: .white.opacity(0.16), location: 0.09), .init(color: clear, location: 0.2),
                    .init(color: clear, location: 0.5), .init(color: .white.opacity(0.11), location: 0.59), .init(color: clear, location: 0.7),
                    .init(color: clear, location: 1)]), center: .center, angle: .degrees(-40))
                    .mask(Ring(inner: labelR * 1.06, outer: R * 0.975).fill(style: FillStyle(eoFill: true)))
                Circle().fill(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 7.2, height: 7.2)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .allowsHitTesting(false)
    }
}

struct Ring: Shape {
    let inner: CGFloat, outer: CGFloat
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path(ellipseIn: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
        p.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
        return p
    }
}

/// The whole deck in its 300 × 250 coordinate space: platter, record and arm.
/// `disc` is the spinning record (the app passes its live Canvas, the widget a DiscView).
struct DeckArt<Disc: View>: View {
    let palette: Palette
    let armAngle: Double
    let playing: Bool
    let armAnimation: Animation
    @ViewBuilder let disc: () -> Disc

    var body: some View {
        let c = Deck.center, R = Deck.radius
        ZStack(alignment: .topLeading) {
            Group {
                if palette.mono {
                    // A ring only: a filled platter would show through the translucent record.
                    Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 3)
                } else {
                    Circle().fill(LinearGradient(colors: [palette.rimLight, palette.rimDark], startPoint: .top, endPoint: .bottom))
                }
            }
                .frame(width: R * 2 + 12, height: R * 2 + 12)
                .shadow(color: palette.shadow.opacity(0.45), radius: 6, y: 4)
                .offset(x: c.x - R - 6, y: c.y - R - 6)
            Circle().fill(palette.mono ? Color.clear : Color(white: 0.1)).frame(width: R * 2 + 4, height: R * 2 + 4).offset(x: c.x - R - 2, y: c.y - R - 2)
            disc().frame(width: R * 2, height: R * 2).offset(x: c.x - R, y: c.y - R)
            SheenView(palette: palette).frame(width: R * 2, height: R * 2).offset(x: c.x - R, y: c.y - R)
            Group {
                Circle().fill(LinearGradient(colors: [palette.rimLight.opacity(0.9), palette.rimDark], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 40, height: 40).shadow(color: palette.shadow.opacity(0.35), radius: 3, y: 2)
                    .offset(x: Deck.pivot.x - 20, y: Deck.pivot.y - 20)
                let rest = Deck.stylus(Deck.restAngle)
                Capsule().fill(palette.rimDark).frame(width: 6, height: 16).offset(x: rest.x - 3, y: rest.y - 30)
                TonearmView(palette: palette)
                    .shadow(color: palette.shadow.opacity(0.4), radius: playing ? 2 : 4, x: -2, y: playing ? 3 : 6)
                    .rotationEffect(.degrees(armAngle), anchor: UnitPoint(x: Deck.pivot.x / Deck.size.width, y: Deck.pivot.y / Deck.size.height))
                    .animation(armAnimation, value: armAngle)
            }
            .allowsHitTesting(false)
        }
        .frame(width: Deck.size.width, height: Deck.size.height, alignment: .topLeading)
    }
}

/// Tonearm angle for a playback position (rest when stopped, outer → inner groove over the song).
func armAngle(playing: Bool, hasTrack: Bool, position: Double, duration: Double, labelSize: Double = 1) -> Double {
    guard hasTrack, playing else { return Deck.restAngle }
    guard duration > 0 else { return Deck.outerGroove + 2 }
    let progress = min(1, max(0, position / duration))
    // A bigger label leaves less groove, so the arm stops before reaching it.
    let inner = labelSize > 1.05 ? Deck.angle(forGroove: max(Deck.radius * 0.46, Deck.labelRadius * labelSize * 1.12 + 4)) : Deck.innerGroove
    return Deck.outerGroove + (inner - Deck.outerGroove) * progress
}

/// The plinth: skin gradient, wood grain for Walnut, and a soft bevel.
struct PlinthBackground<S: InsettableShape>: View {
    let palette: Palette
    let shape: S
    var body: some View {
        ZStack {
            shape.fill(LinearGradient(colors: [palette.top, palette.bottom], startPoint: .top, endPoint: .bottom))
            if palette.wood { WoodGrain().clipShape(shape) }
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.02), .black.opacity(0.25)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
    }
}

// MARK: - State shared with the widget
#if os(macOS)
//
// The sandboxed widget can't read MediaRemote, so the app writes what's playing to
// ~/Library/Application Support/Platter/ (state.json + artwork.jpg). The widget may read only
// that folder (see Widget/PlatterWidget.entitlements). The widget's buttons send commands back
// as Darwin notifications, which the app turns into real play/pause/skip commands.

struct PlayerState: Codable, Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var source: String?
    var playing = false
    var duration: Double = 0
    var position: Double = 0
    var positionDate = Date()
    var skin = Skin.walnut.rawValue
    var style: Style?
    var artColor: [Double]?
    var artworkID: String?

    var hasTrack: Bool { source != nil && (!title.isEmpty || duration > 0) }
    func live(at date: Date) -> Double {
        let p = position + (playing ? date.timeIntervalSince(positionDate) : 0)
        return duration > 0 ? min(duration, max(0, p)) : max(0, p)
    }
    var artNSColor: NSColor? {
        guard let c = artColor, c.count == 3 else { return nil }
        return NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1)
    }

    static let folder = "Library/Application Support/Platter"
    /// The real home folder, even inside the widget's sandbox (where NSHomeDirectory() is the container).
    static var realHome: URL {
        if let dir = getpwuid(getuid())?.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir)) }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    static var directory: URL { realHome.appendingPathComponent(folder) }
    static var stateURL: URL { directory.appendingPathComponent("state.json") }
    static var artworkURL: URL { directory.appendingPathComponent("artwork.jpg") }

    static func load() -> PlayerState {
        guard let data = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(PlayerState.self, from: data) else { return PlayerState() }
        return s
    }
    func save() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.stateURL, options: .atomic) }
    }
    func loadArtwork() -> NSImage? { artworkID == nil ? nil : NSImage(contentsOf: Self.artworkURL) }
}

enum PlatterCommand: String, CaseIterable {
    case toggle, next, previous
    var notificationName: CFNotificationName { CFNotificationName("com.yaksbbgtr.platter.\(rawValue)" as CFString) }
    func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), notificationName, nil, nil, true)
    }
}

#endif

/// Album art that keeps its colours even when macOS draws the widget in monochrome.
struct FullColorImage: View {
    let image: PlatformImage
    var body: some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            Image(platform: image).resizable().widgetAccentedRenderingMode(.fullColor).aspectRatio(contentMode: .fill)
        } else {
            Image(platform: image).resizable().aspectRatio(contentMode: .fill)
        }
    }
}
