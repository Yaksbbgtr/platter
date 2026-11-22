// SPDX-License-Identifier: GPL-3.0-or-later
// The live turntable and the full-screen player, shared by the Mac and iPhone apps. Each app brings
// its own `NowPlaying` (Mac: system Now Playing; iPhone: the Music app) with the same interface.

import SwiftUI

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

/// The record. Grooves look the same at any angle, so they are drawn once; only the label (and a
/// faint glint) turns each frame, which stays smooth even when the record fills the screen.
/// `scale` is how much the deck is enlarged on screen: the grooves are drawn at that size so they stay sharp.
struct RecordView: View {
    @ObservedObject var np: NowPlaying
    @ObservedObject var spinner: Spinner
    let palette: Palette
    var scale: CGFloat = 1

    var body: some View {
        let side = Deck.radius * 2 * scale
        ZStack {
            Canvas { ctx, size in drawGrooves(&ctx, size: size) }
            TimelineView(.animation(minimumInterval: nil, paused: !spinner.running && !spinner.dragging)) { tl in
                label(side: side).rotationEffect(.degrees(spinner.angle(at: tl.date)))
            }
        }
        .frame(width: side, height: side)
        .scaleEffect(1 / scale)
        .frame(width: Deck.radius * 2, height: Deck.radius * 2)
    }

    private func label(side: CGFloat) -> some View {
        let R = side / 2, labelR = R * palette.labelRatio
        return ZStack {
            Circle().fill(Color.white.opacity(0.035)).frame(width: R * 0.1, height: R * 0.1).offset(y: -R * 0.68)
            Group {
                if let art = np.artwork {
                    Image(platform: art).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Circle().fill(palette.accent)
                        Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.7 * scale).padding(labelR * 0.18)
                        Text("PLATTER").font(palette.style.font(labelR * 0.26, .heavy))
                            .foregroundColor(.black.opacity(0.7)).offset(y: -labelR * 0.45)
                        Text("33⅓ RPM").font(palette.style.font(labelR * 0.16, .semibold))
                            .foregroundColor(.black.opacity(0.55)).offset(y: labelR * 0.5)
                    }
                }
            }
            .frame(width: labelR * 2, height: labelR * 2)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.black.opacity(0.45), lineWidth: 1.2 * scale))
        }
        .frame(width: side, height: side)
    }

    private func drawGrooves(_ ctx: inout GraphicsContext, size: CGSize) {
        func circle(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: size.width / 2 - r, y: size.height / 2 - r, width: r * 2, height: r * 2)) }
        let c = CGPoint(x: size.width / 2, y: size.height / 2), R = min(size.width, size.height) / 2
        let labelR = R * palette.labelRatio
        ctx.fill(circle(R), with: .radialGradient(Gradient(colors: [palette.vinylLight, palette.vinylDark]),
                                                  center: c, startRadius: labelR, endRadius: R))
        let inner = labelR * 1.12, outer = R * 0.975, count = scale > 2 ? 128 : 64
        for i in 0..<count {
            let r = inner + (outer - inner) * CGFloat(i) / CGFloat(count - 1)
            ctx.stroke(circle(r), with: .color(palette.groove.opacity(i % 4 == 0 ? 0.055 : 0.03)), lineWidth: 0.6 * max(1, scale * 0.6))
        }
        for f in [0.18, 0.39, 0.57, 0.76] as [CGFloat] {
            ctx.stroke(circle(inner + (outer - inner) * f), with: .color(.black.opacity(palette.gap)), lineWidth: 1.8 * scale)
        }
        ctx.stroke(circle(R - 0.8 * scale), with: .color(.white.opacity(0.12)), lineWidth: scale)
    }
}

struct TurntableDeck: View {
    @ObservedObject var np: NowPlaying
    @ObservedObject var spinner: Spinner
    @ObservedObject var ui: Interaction
    let palette: Palette
    var scale: CGFloat = 1

    private func arm(_ date: Date) -> Double {
        var t = np.live(at: date) + (ui.scrubOffset ?? 0)
        if let b = ui.barScrub { t = b * np.duration }
        return armAngle(playing: np.playing || ui.scrubOffset != nil, hasTrack: np.hasTrack, position: t, duration: np.duration,
                        labelSize: palette.style.labelSize)
    }

    var body: some View {
        let c = Deck.center, R = Deck.radius
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            DeckArt(palette: palette, armAngle: arm(tl.date), playing: np.playing,
                    armAnimation: .spring(response: 1.1, dampingFraction: 0.86)) {
                RecordView(np: np, spinner: spinner, palette: palette, scale: scale)
                    .contentShape(Circle())
                    .gesture(recordGesture)
            }
        }
        .overlay(alignment: .topLeading) {
            if let s = ui.scrubOffset {
                let t = min(max(0, np.live() + s), np.duration > 0 ? np.duration : .infinity)
                Text(formatTime(t)).font(palette.style.font(12, .semibold).monospacedDigit())
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
    var u: CGFloat = 1
    let action: () -> Void
    private var k: CGFloat { u * palette.style.buttonSize }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * k, weight: .semibold))
                .foregroundColor(big ? palette.playIcon : palette.text)
                .frame(width: (big ? 42 : 34) * k, height: (big ? 42 : 34) * k)
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
    var u: CGFloat = 1

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { tl in
            let now = np.live(at: tl.date) + (ui.scrubOffset ?? 0)
            let fraction = ui.barScrub ?? (np.duration > 0 ? min(1, max(0, now / np.duration)) : 0)
            VStack(spacing: 5 * u) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette.track)
                        Capsule().fill(palette.accent).frame(width: max(5 * u, g.size.width * fraction))
                    }
                    .frame(height: (ui.barScrub == nil ? 5 : 7) * u * palette.style.barSize)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in if np.duration > 0 { ui.barScrub = min(1, max(0, v.location.x / g.size.width)) } }
                        .onEnded { _ in if let b = ui.barScrub { np.seek(b * np.duration) }; ui.barScrub = nil })
                }
                .frame(height: max(12, 7 * palette.style.barSize) * u)
                HStack {
                    Text(formatTime(np.duration > 0 ? fraction * np.duration : now))
                    Spacer()
                    Text(np.duration > 0 ? "-" + formatTime(np.duration * (1 - fraction)) : (np.hasTrack ? "LIVE" : ""))
                }
                .font(palette.font(10 * u, .medium).monospacedDigit())
                .foregroundColor(palette.secondary)
                .allowsHitTesting(false)
            }
        }
    }
}


// MARK: - Full screen

struct FullScreenPlayer: View {
    @ObservedObject var np: NowPlaying
    @ObservedObject var spinner: Spinner
    @ObservedObject var ui: Interaction
    @Binding var skin: Skin
    var style = Style()
    /// Buttons and style swatches; they fade away after a few seconds so only the turntable and song remain.
    var showControls: Bool
    var onClose: (() -> Void)?

    var body: some View {
        let palette = Palette.make(skin, art: np.artColor, style: style)
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            Group {
                if w > h { landscape(w, h, palette) } else { portrait(w, h, palette) }
            }
            .frame(width: w, height: h)
        }
        .overlay(alignment: .topTrailing) {
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundColor(palette.text)
                        .frame(width: 38, height: 38).background(Circle().fill(palette.button)).contentShape(Circle())
                }
                .buttonStyle(PressStyle()).padding(22).accessibilityLabel("Exit full screen").faded(!showControls)
            }
        }
        .background(FullScreenBackground(palette: palette).ignoresSafeArea())
        .animation(.easeInOut(duration: 0.6), value: np.artColor)
        .animation(.easeInOut(duration: 0.35), value: showControls)
    }

    private func deck(_ s: CGFloat, _ palette: Palette) -> some View {
        TurntableDeck(np: np, spinner: spinner, ui: ui, palette: palette, scale: s)
            .scaleEffect(s)
            .frame(width: Deck.size.width * s, height: Deck.size.height * s)
    }

    private func landscape(_ w: CGFloat, _ h: CGFloat, _ palette: Palette) -> some View {
        let pad = min(w, h) * 0.055
        let s = min((h - pad * 2) / Deck.size.height, w * 0.6 / Deck.size.width) * style.fullScreenDeck
        let column = min(w - Deck.size.width * s - pad * 3, 560)
        // Sized to the column, but never taller than a short (phone) screen allows.
        let u = min(column / 420, h / 430)
        return HStack(spacing: pad) {
            deck(s, palette)
            info(u, palette, alignment: .leading).frame(width: column)
        }
        .padding(.horizontal, pad)
    }

    private func portrait(_ w: CGFloat, _ h: CGFloat, _ palette: Palette) -> some View {
        let u = min(w / 420, h / 800)
        let s = min((w - 24) / Deck.size.width, h * 0.56 / Deck.size.height) * min(1, style.fullScreenDeck)
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            deck(s, palette)
            Spacer(minLength: 12)
            info(u, palette, alignment: .center).padding(.horizontal, 32 * u)
            Spacer(minLength: 0)
        }
    }

    private func info(_ u: CGFloat, _ palette: Palette, alignment: HorizontalAlignment) -> some View {
        let center = alignment == .center
        return VStack(alignment: alignment, spacing: 22 * u) {
            VStack(alignment: alignment, spacing: 7 * u) {
                Text(np.hasTrack ? (np.title.isEmpty ? (np.source ?? "") : np.title) : "Nothing playing")
                    .font(palette.font(32 * u, .bold)).foregroundColor(palette.text)
                    .lineLimit(2).minimumScaleFactor(0.7)
                Text(np.hasTrack ? np.artist : np.idleHint)
                    .font(palette.font(19 * u, .semibold)).foregroundColor(palette.text.opacity(0.85)).lineLimit(center ? 2 : 1)
                if np.hasTrack && !np.album.isEmpty {
                    Text(np.album).font(palette.font(15 * u, .medium)).foregroundColor(palette.secondary).lineLimit(1)
                }
            }
            .multilineTextAlignment(center ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: center ? .center : .leading)
            .allowsHitTesting(false)
            ProgressBar(np: np, ui: ui, palette: palette, u: 1.35 * u).opacity(np.hasTrack ? 1 : 0.35)
            VStack(spacing: 24 * u) {
                HStack(spacing: 30 * u) {
                    ControlButton(symbol: "backward.fill", size: 14, big: false, palette: palette, u: 1.5 * u, action: np.previous)
                    ControlButton(symbol: np.playing ? "pause.fill" : "play.fill", size: 18, big: true, palette: palette, u: 1.65 * u, action: np.playPause)
                    ControlButton(symbol: "forward.fill", size: 14, big: false, palette: palette, u: 1.5 * u, action: np.next)
                }
                HStack(spacing: 14 * u) {
                    ForEach(Skin.allCases, id: \.self) { choice in
                        let look = Palette.make(choice, art: np.artColor, style: style)
                        Button { skin = choice } label: {
                            Circle().fill(LinearGradient(colors: [look.top, look.bottom], startPoint: .top, endPoint: .bottom))
                                .overlay(Circle().strokeBorder(palette.text.opacity(choice == skin ? 0.95 : 0.25), lineWidth: choice == skin ? 2 : 1))
                                .frame(width: 26 * u, height: 26 * u).padding(4).contentShape(Rectangle())
                        }
                        .buttonStyle(PressStyle()).accessibilityLabel(choice.title)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .faded(!showControls)
        }
    }
}

extension View {
    /// Invisible and untouchable while faded, but keeps its place in the layout.
    func faded(_ hidden: Bool) -> some View { opacity(hidden ? 0 : 1).allowsHitTesting(!hidden) }
}

/// The plinth's surface filling the whole screen, with a soft glow in the song's colour.
struct FullScreenBackground: View {
    let palette: Palette
    var body: some View {
        GeometryReader { g in
            ZStack {
                LinearGradient(colors: [palette.top, palette.bottom], startPoint: .top, endPoint: .bottom)
                if palette.wood { WoodGrain() }
                RadialGradient(colors: [palette.accent.opacity(0.16), palette.accent.opacity(0)], center: .center,
                               startRadius: 0, endRadius: max(g.size.width, g.size.height) * 0.6)
                RadialGradient(colors: [.black.opacity(0), .black.opacity(palette.dark ? 0.35 : 0.08)], center: .center,
                               startRadius: min(g.size.width, g.size.height) * 0.4, endRadius: max(g.size.width, g.size.height) * 0.72)
            }
        }
    }
}
