// SPDX-License-Identifier: GPL-3.0-or-later
// Platter — a vinyl turntable "now playing" widget for the macOS desktop.
//
// The widget follows whatever the system is playing (Music, Spotify, browsers, Podcasts…)
// through the MediaRemote adapter in Adapter/, falling back to Apple Events for Music and
// Spotify. The record spins at 33⅓ rpm with real spin-up / spin-down inertia, the tonearm
// tracks the song's progress across the grooves, and the album art is the record label.
//
//   click the record      play / pause
//   spin the record       scrub (one turn = 15 seconds)
//   drag anywhere else    move the widget
//   right-click           settings (also in the menu bar)

import AppKit
import Combine
import ServiceManagement
import SwiftUI
import WidgetKit

// MARK: - Settings


enum Layout: String, CaseIterable {
    case full, record
    var title: String { self == .full ? "Turntable with Controls" : "Record Only" }
}

enum Placement: String, CaseIterable {
    case desktop, floating
    var title: String { self == .desktop ? "On Desktop (behind windows)" : "Float Above Windows" }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d: UserDefaults
    @Published var skin: Skin { didSet { d.set(skin.rawValue, forKey: "skin") } }
    @Published var layout: Layout { didSet { d.set(layout.rawValue, forKey: "layout") } }
    @Published var placement: Placement { didSet { d.set(placement.rawValue, forKey: "placement") } }
    @Published var scale: Double { didSet { d.set(scale, forKey: "scale") } }
    @Published var visible: Bool { didSet { d.set(visible, forKey: "visible") } }
    static let sizes: [(String, Double)] = [("Small", 0.75), ("Medium", 1.0), ("Large", 1.3)]

    /// `persist: false` (snapshot mode) keeps changes out of the user's real preferences.
    init(persist: Bool = true) {
        d = persist ? .standard : UserDefaults(suiteName: "platter.snapshot") ?? .standard
        skin = Skin(rawValue: d.string(forKey: "skin") ?? "") ?? .walnut
        layout = Layout(rawValue: d.string(forKey: "layout") ?? "") ?? .full
        placement = Placement(rawValue: d.string(forKey: "placement") ?? "") ?? .desktop
        scale = d.object(forKey: "scale") as? Double ?? 1
        visible = d.object(forKey: "visible") as? Bool ?? true
    }
}

// MARK: - Now Playing
//
// Primary source: the system-wide Now Playing session read by the MediaRemote adapter
// (adapted from Vorssaint, see Adapter/). macOS 15.4+ only answers Apple-signed processes,
// so the adapter runs inside /usr/bin/perl and streams JSON lines to us. If it can't run,
// we poll Music and Spotify over Apple Events instead.

final class NowPlaying: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var playing = false
    @Published var duration: Double = 0
    @Published var artwork: NSImage?
    @Published var artColor: NSColor?
    @Published var source: String?
    @Published var sourceIcon: NSImage?
    @Published var bundleID: String?
    /// Last known position and the moment it was sampled; `live(at:)` extrapolates.
    @Published var position: Double = 0
    var positionDate = Date()
    var hasTrack: Bool { source != nil && (!title.isEmpty || duration > 0) }

    private let queue = DispatchQueue(label: "platter.nowplaying")
    private var busy = false
    private var key = ""
    private var adapter: Process?
    private var adapterIn: FileHandle?
    private var lineBuffer = Data()
    private var adapterFailures = 0
    private var pollTimer: Timer?
    private(set) var useAppleScript = false
    static let players = [("Spotify", "com.spotify.client"), ("Music", "com.apple.Music")]

    func live(at date: Date = Date()) -> Double {
        let p = position + (playing ? date.timeIntervalSince(positionDate) : 0)
        return duration > 0 ? min(duration, max(0, p)) : max(0, p)
    }
    private func setPosition(_ p: Double) { position = p; positionDate = Date() }

    // MARK: Adapter

    func start() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() }
        guard let script = Bundle.main.url(forResource: "now-playing", withExtension: "pl"),
              let library = Bundle.main.privateFrameworksURL?.appendingPathComponent("libPlatterNowPlaying.dylib"),
              FileManager.default.fileExists(atPath: library.path) else { useAppleScript = true; return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, library.path, "watch"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.adapter = nil; self.adapterIn = nil
                self.adapterFailures += 1
                if self.adapterFailures >= 3 { self.useAppleScript = true } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.start() }
                }
            }
        }
        do { try process.run(); adapter = process; adapterIn = input.fileHandleForWriting } catch { useAppleScript = true }
    }

    func stop() { adapter?.terminationHandler = nil; try? adapterIn?.close(); adapter?.terminate() }

    private func consume(_ data: Data) {
        lineBuffer.append(data)
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer[lineBuffer.startIndex..<nl]
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let error = json["error"] as? String { if error != "metadata timeout" { useAppleScript = true }; continue }
            if json["sent"] != nil { continue }
            adapterFailures = 0
            applyAdapter(json)
        }
    }

    private func applyAdapter(_ j: [String: Any]) {
        let t = j["title"] as? String ?? "", d = j["duration"] as? Double ?? 0
        guard var bundle = j["bundleID"] as? String, !t.isEmpty || d > 0 else { clear(); return }
        if bundle.hasPrefix("com.apple.WebKit") { bundle = "com.apple.Safari" }
        setSource(bundle: bundle, name: nil)
        title = t; artist = j["artist"] as? String ?? ""; album = j["album"] as? String ?? ""
        duration = d
        if let e = j["elapsed"] as? Double { setPosition(e) }
        let isPlaying = (j["playing"] as? Bool) ?? ((j["rate"] as? Double ?? 0) > 0)
        if playing != isPlaying { playing = isPlaying }
        if let b64 = j["artwork"] as? String, let data = Data(base64Encoded: b64) { setArtwork(NSImage(data: data)) }
        else if j["noArtwork"] as? Bool == true { setArtwork(nil) }
        key = bundle + t + artist + album
    }

    private func setSource(bundle: String, name: String?) {
        guard bundle != bundleID else { return }
        bundleID = bundle
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        source = name ?? url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundle
        sourceIcon = url.flatMap(Self.appIcon)
    }

    /// Flattens the workspace icon to a plain 64px bitmap (multi-rep icons render oddly in SwiftUI snapshots).
    static func appIcon(_ url: URL) -> NSImage? {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return icon }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 32, height: 32)); image.addRepresentation(rep)
        return image
    }

    /// Bumped whenever the artwork changes, so the widget knows to re-read artwork.jpg.
    private(set) var artworkVersion = 0

    func setArtwork(_ image: NSImage?) {
        if image !== artwork { artworkVersion += 1 }
        artwork = image
        artColor = image.flatMap(averageColor)
    }

    private func clear() {
        guard source != nil else { return }
        source = nil; sourceIcon = nil; bundleID = nil; title = ""; artist = ""; album = ""
        playing = false; duration = 0; setPosition(0); setArtwork(nil); key = ""
    }

    // MARK: Apple Events fallback

    @discardableResult
    static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    func poll() {
        guard useAppleScript, !busy else { return }
        let running = Self.players.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.1).isEmpty }
        guard !running.isEmpty else { clear(); return }
        busy = true
        queue.async {
            var best: [String]?; var bestApp: (String, String)?
            for app in running {
                let script = """
                tell application "\(app.0)"
                    if player state is stopped then return ""
                    set t to current track
                    return (name of t as text) & "|~|" & (artist of t as text) & "|~|" & (album of t as text) & "|~|" & (player position as text) & "|~|" & (duration of t as text) & "|~|" & (player state as text)
                end tell
                """
                guard let out = Self.run(script)?.stringValue, !out.isEmpty else { continue }
                let parts = out.components(separatedBy: "|~|")
                guard parts.count == 6 else { continue }
                if best == nil || (parts[5] == "playing" && best?[5] != "playing") { best = parts; bestApp = app }
            }
            DispatchQueue.main.async { self.busy = false; self.applyScript(best, app: bestApp) }
        }
    }

    private func applyScript(_ parts: [String]?, app: (String, String)?) {
        guard let parts, let app else { clear(); return }
        let num = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        setSource(bundle: app.1, name: app.0)
        title = parts[0]; artist = parts[1]; album = parts[2]
        setPosition(num(parts[3]))
        duration = num(parts[4]) / (app.0 == "Spotify" ? 1000 : 1)
        let isPlaying = parts[5] == "playing"
        if playing != isPlaying { playing = isPlaying }
        let newKey = app.0 + parts[0] + parts[1] + parts[2]
        if newKey != key { key = newKey; fetchArtwork(app.0) }
    }

    private func fetchArtwork(_ app: String) {
        setArtwork(nil)
        let expected = key
        let deliver = { (img: NSImage) in DispatchQueue.main.async { if self.key == expected { self.setArtwork(img) } } }
        queue.async {
            if app == "Music" {
                let d = Self.run("tell application \"Music\" to get raw data of artwork 1 of current track")?.data
                    ?? Self.run("tell application \"Music\" to get data of artwork 1 of current track")?.data
                if let d, let img = NSImage(data: d) { deliver(img) }
            } else if let s = Self.run("tell application \"Spotify\" to get artwork url of current track")?.stringValue, let url = URL(string: s) {
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    if let data, let img = NSImage(data: data) { deliver(img) }
                }.resume()
            }
        }
    }

    // MARK: Controls

    private func command(_ line: String, script: String) {
        if let input = adapterIn, !useAppleScript {
            try? input.write(contentsOf: Data((line + "\n").utf8))
        } else if let app = source, Self.players.contains(where: { $0.0 == app }) {
            queue.async {
                Self.run("tell application \"\(app)\" to \(script)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.poll() }
            }
        }
    }
    func playPause() {
        guard hasTrack else { openMusic(); return }
        setPosition(live()); playing.toggle(); command("toggle", script: "playpause")
    }
    func next() { command("next", script: "next track") }
    func previous() { command("previous", script: "previous track") }
    func seek(_ t: Double) {
        setPosition(t)
        command("seek " + String(format: "%.2f", t), script: "set player position to \(String(format: "%.2f", t))")
    }
    func openMusic() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
    func openSource() {
        if let bundleID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { app.activate() }
    }
}


// MARK: - Record spin (33⅓ rpm with inertia)

final class Spinner: ObservableObject {
    @Published var running = false
    @Published var dragging = false
    var angle: Double = 0
    private var speed: Double = 0
    private var target: Double = 0
    private var last: Date?

    func setPlaying(_ on: Bool) {
        target = on ? 200 : 0      // 33⅓ rpm = 200°/s
        if on && !running { last = nil; running = true }
    }

    func angle(at date: Date) -> Double {
        defer { last = date }
        guard !dragging else { return angle }
        let dt = last.map { min(0.1, max(0, date.timeIntervalSince($0))) } ?? 0
        speed += (target - speed) * min(1, dt * (target > speed ? 2.6 : 1.4))
        if target == 0 && speed < 2 {
            speed = 0
            if running { DispatchQueue.main.async { if self.target == 0 { self.running = false } } }
        }
        angle = (angle + speed * dt).truncatingRemainder(dividingBy: 360)
        return angle
    }
}

/// Transient interaction state (kept in an object rather than @State: see README, toolchain note).
final class Interaction: ObservableObject {
    @Published var hover = false
    @Published var scrubOffset: Double?        // seconds added while spinning the record by hand
    @Published var barScrub: Double?           // 0…1 while dragging the progress bar
    var lastFinger: Double?
    var turned: Double = 0
    var startAngle: Double = 0
    var moved = false
}

// MARK: - Views

struct RecordView: View {
    @ObservedObject var np: NowPlaying
    @ObservedObject var spinner: Spinner
    let palette: Palette

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !spinner.running && !spinner.dragging)) { tl in
            let angle = spinner.angle(at: tl.date)
            Canvas { ctx, size in draw(&ctx, size: size, angle: angle) }
        }
    }

    private func circle(_ c: CGPoint, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, angle: Double) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2), R = min(size.width, size.height) / 2
        let labelR = R * Deck.labelRadius / Deck.radius
        ctx.fill(circle(c, R), with: .radialGradient(Gradient(colors: [Color(white: 0.09), Color(white: 0.04)]),
                                                     center: c, startRadius: labelR, endRadius: R))
        var disc = ctx
        disc.translateBy(x: c.x, y: c.y); disc.rotate(by: .degrees(angle)); disc.translateBy(x: -c.x, y: -c.y)

        // Grooves, with a few darker gaps between tracks.
        let inner = labelR * 1.12, outer = R * 0.975, count = 64
        for i in 0..<count {
            let r = inner + (outer - inner) * CGFloat(i) / CGFloat(count - 1)
            disc.stroke(circle(c, r), with: .color(.white.opacity(i % 4 == 0 ? 0.055 : 0.03)), lineWidth: 0.6)
        }
        for f in [0.18, 0.39, 0.57, 0.76] as [CGFloat] {
            disc.stroke(circle(c, inner + (outer - inner) * f), with: .color(.black.opacity(0.75)), lineWidth: 1.8)
        }
        disc.stroke(circle(c, R - 0.8), with: .color(.white.opacity(0.12)), lineWidth: 1)
        // A faint off-centre glint that turns with the disc so motion reads even on a plain label.
        disc.fill(circle(CGPoint(x: c.x, y: c.y - R * 0.68), R * 0.05), with: .color(.white.opacity(0.035)))

        // Label: the album art, or a printed paper label.
        let labelRect = CGRect(x: c.x - labelR, y: c.y - labelR, width: labelR * 2, height: labelR * 2)
        if let art = np.artwork {
            var l = disc
            l.clip(to: circle(c, labelR))
            l.draw(Image(nsImage: art).resizable(), in: labelRect)
        } else {
            disc.fill(circle(c, labelR), with: .color(palette.accent))
            disc.stroke(circle(c, labelR * 0.82), with: .color(.black.opacity(0.18)), lineWidth: 0.7)
            disc.draw(Text("PLATTER").font(.system(size: labelR * 0.26, weight: .heavy, design: .rounded)).foregroundColor(.black.opacity(0.7)),
                      at: CGPoint(x: c.x, y: c.y - labelR * 0.45))
            disc.draw(Text("33⅓ RPM").font(.system(size: labelR * 0.16, weight: .semibold, design: .rounded)).foregroundColor(.black.opacity(0.55)),
                      at: CGPoint(x: c.x, y: c.y + labelR * 0.5))
        }
        disc.stroke(circle(c, labelR), with: .color(.black.opacity(0.45)), lineWidth: 1.2)
    }
}


struct TurntableDeck: View {
    @ObservedObject var np: NowPlaying
    @ObservedObject var spinner: Spinner
    @ObservedObject var ui: Interaction
    let palette: Palette

    private func arm(_ date: Date) -> Double {
        var t = np.live(at: date) + (ui.scrubOffset ?? 0)
        if let b = ui.barScrub { t = b * np.duration }
        return armAngle(playing: np.playing || ui.scrubOffset != nil, hasTrack: np.hasTrack, position: t, duration: np.duration)
    }

    var body: some View {
        let c = Deck.center, R = Deck.radius
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            DeckArt(palette: palette, armAngle: arm(tl.date), playing: np.playing,
                    armAnimation: .spring(response: 1.1, dampingFraction: 0.86)) {
                RecordView(np: np, spinner: spinner, palette: palette)
                    .contentShape(Circle())
                    .gesture(recordGesture)
            }
        }
        .overlay(alignment: .topLeading) {
            if let s = ui.scrubOffset {
                let t = min(max(0, np.live() + s), np.duration > 0 ? np.duration : .infinity)
                Text(formatTime(t)).font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(.white).padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.65)))
                    .frame(width: 80).offset(x: c.x - 40, y: c.y + R * 0.52).allowsHitTesting(false)
            }
        }
        .frame(width: Deck.size.width, height: Deck.size.height, alignment: .topLeading)
    }

    private var recordGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let R = Deck.radius
                let finger = atan2(v.location.y - R, v.location.x - R) * 180 / .pi
                if ui.lastFinger == nil { ui.lastFinger = finger; ui.turned = 0; ui.moved = false; ui.startAngle = spinner.angle }
                var delta = finger - (ui.lastFinger ?? finger)
                if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
                ui.lastFinger = finger
                ui.turned += delta
                if !ui.moved && hypot(v.translation.width, v.translation.height) > 4 && np.hasTrack {
                    ui.moved = true; spinner.dragging = true
                }
                if ui.moved {
                    spinner.angle = ui.startAngle + ui.turned
                    ui.scrubOffset = ui.turned / 360 * 15
                }
            }
            .onEnded { _ in
                if ui.moved, let s = ui.scrubOffset {
                    let t = np.live() + s
                    np.seek(min(max(0, t), np.duration > 0 ? np.duration - 0.5 : t))
                } else if !ui.moved {
                    np.playPause()
                }
                spinner.dragging = false
                ui.scrubOffset = nil; ui.lastFinger = nil; ui.moved = false
            }
    }
}

struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let big: Bool
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(big ? (palette.wood || palette.text == .white ? .black.opacity(0.8) : .white) : palette.text)
                .frame(width: big ? 42 : 34, height: big ? 42 : 34)
                .background(Circle().fill(big ? palette.accent : palette.button))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.9 : 1).animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}


struct ProgressBar: View {
    @ObservedObject var np: NowPlaying
    @ObservedObject var ui: Interaction
    let palette: Palette

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { tl in
            let now = np.live(at: tl.date) + (ui.scrubOffset ?? 0)
            let fraction = ui.barScrub ?? (np.duration > 0 ? min(1, max(0, now / np.duration)) : 0)
            VStack(spacing: 5) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette.track)
                        Capsule().fill(palette.accent).frame(width: max(5, g.size.width * fraction))
                    }
                    .frame(height: ui.barScrub == nil ? 5 : 7)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in if np.duration > 0 { ui.barScrub = min(1, max(0, v.location.x / g.size.width)) } }
                        .onEnded { _ in if let b = ui.barScrub { np.seek(b * np.duration) }; ui.barScrub = nil })
                }
                .frame(height: 12)
                HStack {
                    Text(formatTime(np.duration > 0 ? fraction * np.duration : now))
                    Spacer()
                    Text(np.duration > 0 ? "-" + formatTime(np.duration * (1 - fraction)) : "LIVE")
                }
                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundColor(palette.secondary)
                .allowsHitTesting(false)
            }
        }
    }
}

struct InfoPanel: View {
    @ObservedObject var np: NowPlaying
    @ObservedObject var ui: Interaction
    let palette: Palette

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(np.hasTrack ? (np.title.isEmpty ? (np.source ?? "") : np.title) : "Nothing playing")
                        .font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundColor(palette.text)
                    Text(np.hasTrack ? [np.artist, np.album].filter { !$0.isEmpty }.joined(separator: " — ") : "Play something in Music, Spotify or a browser")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(palette.secondary)
                }
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
                if let icon = np.sourceIcon {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                        .contentShape(Rectangle()).onTapGesture(perform: np.openSource)
                }
            }
            ProgressBar(np: np, ui: ui, palette: palette).opacity(np.hasTrack ? 1 : 0.35)
            HStack(spacing: 22) {
                ControlButton(symbol: "backward.fill", size: 13, big: false, palette: palette, action: np.previous)
                ControlButton(symbol: np.playing ? "pause.fill" : "play.fill", size: 17, big: true, palette: palette, action: np.playPause)
                ControlButton(symbol: "forward.fill", size: 13, big: false, palette: palette, action: np.next)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 2)
        .padding(.bottom, 24)
    }
}

/// Lets the bare plinth drag the borderless window.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

struct FloatingWidget: View {
    @ObservedObject var np: NowPlaying
    @ObservedObject var spinner: Spinner
    @ObservedObject var settings: Settings
    @ObservedObject var ui: Interaction
    var interactive = true

    static func cardSize(_ layout: Layout) -> CGSize {
        CGSize(width: Deck.size.width, height: layout == .full ? Deck.size.height + 150 : Deck.size.height)
    }

    var body: some View {
        let palette = Palette.make(settings.skin, art: np.artColor)
        let size = Self.cardSize(settings.layout)
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        VStack(spacing: 0) {
            TurntableDeck(np: np, spinner: spinner, ui: ui, palette: palette)
            if settings.layout == .full { InfoPanel(np: np, ui: ui, palette: palette) }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(
            ZStack {
                PlinthBackground(palette: palette, shape: shape)
                if interactive { WindowDragArea().clipShape(shape) }
            }
            .shadow(color: .black.opacity(0.45), radius: 16, y: 10)
        )
        .overlay(alignment: .bottom) {
            if settings.layout == .record && ui.hover && np.hasTrack { hoverBar(palette) }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { ui.hover = h } }
        .padding(28)
        .animation(.easeInOut(duration: 0.6), value: np.artColor)
    }

    private func hoverBar(_ palette: Palette) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(np.title).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(.white)
                Text(np.artist).font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.65))
            }
            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: np.previous) { Image(systemName: "backward.fill") }
            Button(action: np.playPause) { Image(systemName: np.playing ? "pause.fill" : "play.fill").frame(width: 16) }
            Button(action: np.next) { Image(systemName: "forward.fill") }
        }
        .buttonStyle(PressStyle())
        .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Capsule().fill(.black.opacity(0.72)))
        .padding(.horizontal, 14).padding(.bottom, 10)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

// MARK: - Window & menu bar

struct RootView: View {
    @ObservedObject var np: NowPlaying
    @ObservedObject var spinner: Spinner
    @ObservedObject var settings: Settings
    @ObservedObject var ui: Interaction
    var body: some View {
        FloatingWidget(np: np, spinner: spinner, settings: settings, ui: ui)
            .scaleEffect(settings.scale, anchor: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class HostingView<V: View>: NSHostingView<V> {
    var menuProvider: (() -> NSMenu)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

final class ClosureItem: NSMenuItem {
    private var handler: (() -> Void)?
    convenience init(_ title: String, checked: Bool = false, key: String = "", handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: key)
        self.handler = handler; target = self; state = checked ? .on : .off
    }
    @objc private func fire() { handler?() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let np = NowPlaying()
    let spinner = Spinner()
    let ui = Interaction()
    let settings = Settings.shared
    var panel: WidgetPanel!
    var status: NSStatusItem!
    var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ note: Notification) {
        let host = HostingView(rootView: rootView)
        host.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }
        panel = WidgetPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.contentView = host
        resize(initial: true)
        panel.setFrameAutosaveName("PlatterWidget")
        applyPlacement()

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Platter")
        let menu = NSMenu(); menu.delegate = self
        status.menu = menu

        np.$playing.sink { [weak self] p in self?.spinner.setPlaying(p) }.store(in: &bag)
        settings.$layout.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.resize() } }.store(in: &bag)
        settings.$scale.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.resize() } }.store(in: &bag)
        settings.$placement.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.applyPlacement() } }.store(in: &bag)
        settings.$visible.sink { [weak self] v in DispatchQueue.main.async { v ? self?.panel.orderFront(nil) : self?.panel.orderOut(nil) } }.store(in: &bag)
        np.objectWillChange.merge(with: settings.$skin.map { _ in () }.eraseToAnyPublisher())
            .debounce(for: .seconds(0.4), scheduler: RunLoop.main)
            .sink { [weak self] in self?.publishState() }.store(in: &bag)
        listenForWidgetCommands()
        np.start()
        publishState(force: true)
    }

    func applicationWillTerminate(_ note: Notification) {
        np.stop()
        var st = lastState; st.playing = false; st.source = nil; st.save()   // the widget can't follow playback without us
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Desktop widget bridge

    private var lastState = PlayerState()
    private var lastArtworkVersion = -1

    /// Writes what's playing for the WidgetKit widget; reloads it only when something it shows changed.
    func publishState(force: Bool = false) {
        let now = Date()
        var st = PlayerState()
        st.title = np.title; st.artist = np.artist; st.album = np.album; st.source = np.source
        st.playing = np.playing; st.duration = np.duration
        st.position = np.live(at: now); st.positionDate = now
        st.skin = settings.skin.rawValue
        if let c = np.artColor?.usingColorSpace(.sRGB) { st.artColor = [c.redComponent, c.greenComponent, c.blueComponent].map(Double.init) }
        if np.artworkVersion != lastArtworkVersion {
            lastArtworkVersion = np.artworkVersion
            try? FileManager.default.createDirectory(at: PlayerState.directory, withIntermediateDirectories: true)
            if let art = np.artwork, let jpeg = Self.jpeg(art, side: 200) { try? jpeg.write(to: PlayerState.artworkURL, options: .atomic) }
            else { try? FileManager.default.removeItem(at: PlayerState.artworkURL) }
        }
        st.artworkID = np.artwork == nil ? nil : String(np.artworkVersion)
        var a = st, b = lastState
        a.position = 0; a.positionDate = .distantPast; b.position = 0; b.positionDate = .distantPast
        let drift = abs(st.live(at: now) - lastState.live(at: now))
        guard force || a != b || drift > 2.5 else { return }
        lastState = st
        st.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func jpeg(_ image: NSImage, side: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    /// The widget's buttons post Darwin notifications (all a sandboxed widget can do); act on them here.
    func listenForWidgetCommands() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for cmd in PlatterCommand.allCases {
            CFNotificationCenterAddObserver(center, Unmanaged.passUnretained(self).toOpaque(), { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let me = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
                let raw = (name.rawValue as String).components(separatedBy: ".").last ?? ""
                DispatchQueue.main.async {
                    switch PlatterCommand(rawValue: raw) {
                    case .toggle: me.np.playPause()
                    case .next: me.np.next()
                    case .previous: me.np.previous()
                    case nil: break
                    }
                }
            }, cmd.notificationName.rawValue, nil, .deliverImmediately)
        }
    }

    @objc func showWidgetHelp() {
        let alert = NSAlert()
        alert.messageText = "Add Platter to your desktop"
        alert.informativeText = """
        Right-click the desktop → Edit Widgets…, search for Platter, and drag the Small, Medium or Large turntable onto your desktop.

        Right-click a widget → Edit "Platter" to give it its own style. Keep Platter running (it lives in the menu bar) — it tells the widget what's playing and carries out its buttons.

        macOS dims desktop widgets while another app is in front. For full colour all the time: System Settings → Desktop & Dock → Widget style → Full-color.
        """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    var rootView: RootView { RootView(np: np, spinner: spinner, settings: settings, ui: ui) }

    func resize(initial: Bool = false) {
        let card = FloatingWidget.cardSize(settings.layout)
        let s = settings.scale
        let size = NSSize(width: (card.width + 56) * s, height: (card.height + 56) * s)
        if initial, let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrame(NSRect(x: v.maxX - size.width - 8, y: v.minY + 8, width: size.width, height: size.height), display: true)
        } else {
            let top = panel.frame.maxY
            panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true, animate: true)
        }
    }

    func applyPlacement() {
        if settings.placement == .desktop {
            // Just under normal windows: app windows cover it, but it stays above the wallpaper and system desktop widgets.
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        } else {
            panel.level = .floating
        }
        if settings.visible { panel.orderFront(nil) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in buildMenu().items { item.menu?.removeItem(item); menu.addItem(item) }
    }

    func buildMenu() -> NSMenu {
        let m = NSMenu()
        if np.hasTrack {
            let now = NSMenuItem(title: "♫ " + [np.title, np.artist].filter { !$0.isEmpty }.joined(separator: " — "), action: nil, keyEquivalent: "")
            now.isEnabled = false; m.addItem(now)
            m.addItem(ClosureItem(np.playing ? "Pause" : "Play") { [np] in np.playPause() })
            m.addItem(ClosureItem("Next Track") { [np] in np.next() })
            m.addItem(.separator())
        }
        m.addItem(ClosureItem("Floating Turntable", checked: settings.visible) { [settings] in settings.visible.toggle() })
        m.addItem(ClosureItem("Add Desktop Widget…") { [weak self] in self?.showWidgetHelp() })
        m.addItem(.separator())
        m.addItem(submenu("Style", Skin.allCases.map { s in ClosureItem(s.title, checked: settings.skin == s) { [settings] in settings.skin = s } }))
        m.addItem(submenu("Size", Settings.sizes.map { s in ClosureItem(s.0, checked: abs(settings.scale - s.1) < 0.01) { [settings] in settings.scale = s.1 } }))
        m.addItem(submenu("Layout", Layout.allCases.map { l in ClosureItem(l.title, checked: settings.layout == l) { [settings] in settings.layout = l } }))
        m.addItem(submenu("Position", Placement.allCases.map { p in ClosureItem(p.title, checked: settings.placement == p) { [settings] in settings.placement = p } }))
        let login = SMAppService.mainApp.status == .enabled
        m.addItem(ClosureItem("Launch at Login", checked: login) {
            do { if login { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() } } catch { NSSound.beep() }
        })
        m.addItem(.separator())
        m.addItem(ClosureItem("Quit Platter", key: "q") { NSApp.terminate(nil) })
        return m
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(); items.forEach(sub.addItem); item.submenu = sub
        return item
    }
}

// MARK: - Snapshot mode (renders the widget to PNG for README / checks)

@MainActor func snapshot(_ path: String, skin: Skin, layout: Layout, playing: Bool) {
    let np = NowPlaying(), settings = Settings(persist: false), spinner = Spinner(), ui = Interaction()
    settings.skin = skin; settings.layout = layout
    if playing {
        let art = NSImage(size: NSSize(width: 300, height: 300), flipped: false) { r in
            NSGradient(colors: [NSColor(srgbRed: 0.95, green: 0.45, blue: 0.3, alpha: 1), NSColor(srgbRed: 0.45, green: 0.2, blue: 0.6, alpha: 1)])!.draw(in: r, angle: -60)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 95, y: 150, width: 110, height: 110)).fill()
            NSColor.black.withAlphaComponent(0.25).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 300, height: 110)).fill()
            return true
        }
        np.source = "Music"; np.bundleID = "com.apple.Music"
        np.sourceIcon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music").flatMap(NowPlaying.appIcon)
        np.title = "Golden Hour Static"; np.artist = "The Low Orbits"; np.album = "Side A"
        np.duration = 214; np.position = 88; np.playing = true
        np.setArtwork(art)
        spinner.angle = 30
    }
    let view = FloatingWidget(np: np, spinner: spinner, settings: settings, ui: ui, interactive: false)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let cg = renderer.cgImage else { print("render failed"); exit(1) }
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print(path)
}

// MARK: - Entry

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    _ = NSApplication.shared
    let skin = args.count > i + 2 ? Skin(rawValue: args[i + 2]) ?? .walnut : .walnut
    let layout = args.count > i + 3 ? Layout(rawValue: args[i + 3]) ?? .full : .full
    let playing = !(args.count > i + 4 && args[i + 4] == "idle")
    MainActor.assumeIsolated { snapshot(args[i + 1], skin: skin, layout: layout, playing: playing) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
