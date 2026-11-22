// SPDX-License-Identifier: GPL-3.0-or-later
// Platter's desktop widget (WidgetKit). The app writes what's playing to a small state file; the
// widget draws it as a turntable whose record turns between timeline entries, and its buttons
// send play/pause/skip back to the app.

import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Buttons

struct TogglePlaybackIntent: AppIntent {
    static var title: LocalizedStringResource = "Play or Pause"
    static var isDiscoverable = false
    func perform() async throws -> some IntentResult { PlatterCommand.toggle.post(); return .result() }
}

struct NextTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Track"
    static var isDiscoverable = false
    func perform() async throws -> some IntentResult { PlatterCommand.next.post(); return .result() }
}

struct PreviousTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var isDiscoverable = false
    func perform() async throws -> some IntentResult { PlatterCommand.previous.post(); return .result() }
}

// MARK: - Per-widget style (right-click the widget → Edit "Platter")

enum StyleChoice: String, AppEnum {
    case app, walnut, midnight, arctic, album
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Style")
    static var caseDisplayRepresentations: [StyleChoice: DisplayRepresentation] = [
        .app: "Same as the app", .walnut: "Walnut", .midnight: "Midnight", .arctic: "Arctic", .album: "Album Colors",
    ]
}

struct PlatterConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Platter"
    static var description = IntentDescription("Choose this turntable's style.")

    @Parameter(title: "Style", default: .app)
    var style: StyleChoice
}

// MARK: - Timeline

struct DeckEntry: TimelineEntry {
    let date: Date
    let state: PlayerState
    let artwork: NSImage?
    let skin: Skin
    let spin: Double
    let arm: Double
}

struct DeckProvider: AppIntentTimelineProvider {
    /// Degrees the record turns per entry. macOS redraws widgets about every two seconds, so the
    /// record steps a quarter turn per entry and animates linearly between them.
    static let step: TimeInterval = 2
    static let turn: Double = 90

    func placeholder(in context: Context) -> DeckEntry {
        entry(PlayerState(), art: nil, skin: .walnut, at: .now, spin: SpinClock.angle(at: .now))
    }

    func snapshot(for config: PlatterConfig, in context: Context) async -> DeckEntry {
        var st = PlayerState.load()
        if context.isPreview && !st.hasTrack {
            st.source = "Music"; st.title = "Golden Hour Static"; st.artist = "The Low Orbits"
            st.duration = 214; st.position = 88; st.playing = true
        }
        return entry(st, art: st.loadArtwork(), skin: skin(config, st), at: .now, spin: SpinClock.angle(at: .now))
    }

    func timeline(for config: PlatterConfig, in context: Context) async -> Timeline<DeckEntry> {
        let st = PlayerState.load(), art = st.loadArtwork(), skin = skin(config, st)
        let now = Date()
        let playing = st.hasTrack && st.playing
        let start = SpinClock.restart(at: now, playing: playing)
        guard playing else {
            return Timeline(entries: [entry(st, art: art, skin: skin, at: now, spin: start)], policy: .never)
        }
        // About a minute of turning (less if the song ends sooner); then WidgetKit asks again. macOS
        // rejects a timeline whose archive gets too big and leaves the widget on its placeholder,
        // which the Large size hit with two minutes of entries.
        let remaining = st.duration > 0 ? max(Self.step, st.duration - st.live(at: now)) : 60
        let count = Int(min(60, remaining) / Self.step) + 1
        let entries = (0..<count).map { i in
            entry(st, art: art, skin: skin, at: now.addingTimeInterval(Double(i) * Self.step), spin: start + Double(i) * Self.turn)
        }
        return Timeline(entries: entries, policy: .atEnd)
    }

    private func skin(_ config: PlatterConfig, _ st: PlayerState) -> Skin {
        config.style == .app ? (Skin(rawValue: st.skin) ?? .walnut) : (Skin(rawValue: config.style.rawValue) ?? .walnut)
    }

    private func entry(_ st: PlayerState, art: NSImage?, skin: Skin, at date: Date, spin: Double) -> DeckEntry {
        DeckEntry(date: date, state: st, artwork: art, skin: skin, spin: spin,
                  arm: armAngle(playing: st.playing, hasTrack: st.hasTrack, position: st.live(at: date), duration: st.duration))
    }
}

/// The record's angle, kept continuous across timelines. Each new timeline starts from wherever the
/// last one had got to (angles only ever grow), so a reload never spins the record back, and a
/// paused record resumes from where it stopped. Stored in the widget's own defaults.
enum SpinClock {
    private static let defaults = UserDefaults.standard
    private static var rate: Double { DeckProvider.turn / DeckProvider.step }   // degrees per second

    static func angle(at date: Date) -> Double {
        let base = defaults.double(forKey: "spinBase"), since = defaults.double(forKey: "spinSince")
        guard since > 0, defaults.bool(forKey: "spinPlaying") else { return base }
        return base + max(0, date.timeIntervalSince1970 - since) * rate
    }

    /// Freezes the current angle as the new starting point and returns it.
    static func restart(at date: Date, playing: Bool) -> Double {
        let a = angle(at: date)
        defaults.set(a, forKey: "spinBase")
        defaults.set(date.timeIntervalSince1970, forKey: "spinSince")
        defaults.set(playing, forKey: "spinPlaying")
        return a
    }
}

// MARK: - Views

struct ScaledDeck: View {
    let entry: DeckEntry
    let palette: Palette
    let scale: CGFloat

    var body: some View {
        Button(intent: TogglePlaybackIntent()) {
            DeckArt(palette: palette, armAngle: entry.arm, playing: entry.state.playing,
                    armAnimation: .easeInOut(duration: 1.6)) {
                DiscView(artwork: entry.artwork, palette: palette)
                    .rotationEffect(.degrees(entry.spin))
                    .animation(.linear(duration: DeckProvider.step), value: entry.spin)
            }
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: Deck.size.width * scale, height: Deck.size.height * scale, alignment: .topLeading)
        }
        .buttonStyle(.plain)
    }
}

struct TrackText: View {
    let state: PlayerState
    let palette: Palette
    let titleSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(state.hasTrack ? (state.title.isEmpty ? (state.source ?? "") : state.title) : "Nothing playing")
                .font(.system(size: titleSize, weight: .semibold, design: .rounded)).foregroundColor(palette.text)
            Text(state.hasTrack ? [state.artist, state.album].filter { !$0.isEmpty }.joined(separator: " — ") : "Open Platter and play some music")
                .font(.system(size: titleSize * 0.8, weight: .medium, design: .rounded)).foregroundColor(palette.secondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WidgetProgress: View {
    let state: PlayerState
    let date: Date
    let palette: Palette
    var showTimes = true

    var body: some View {
        let pos = state.live(at: date)
        let start = date.addingTimeInterval(-pos)
        let end = start.addingTimeInterval(max(state.duration, 1))
        VStack(spacing: 3) {
            // A drawn bar rather than ProgressView: in clear/monochrome widget mode macOS paints
            // ProgressView's track and fill the same white, so it always looked full. The fill
            // follows the timeline entries (every 2 s) and glides linearly between them.
            let fraction = state.duration > 0 ? min(1, max(0, pos / state.duration)) : 0
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.track)
                    Capsule().fill(palette.accent)
                        .frame(width: max(4, g.size.width * fraction))
                        .animation(.linear(duration: DeckProvider.step), value: fraction)
                }
            }
            .frame(height: 4)
            if showTimes {
                HStack {
                    if state.playing && state.duration > 0 {
                        // Live timer text fills its whole frame, so pin each one to its own side.
                        Text(timerInterval: start...end, countsDown: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(timerInterval: start...end, countsDown: true)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        Text(formatTime(pos))
                        Spacer()
                        Text(state.duration > 0 ? formatTime(state.duration - pos) : "")
                    }
                }
                .font(.system(size: 9.5, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundColor(palette.secondary)
            }
        }
        .opacity(state.hasTrack ? 1 : 0.35)
    }
}

struct WidgetControls: View {
    let playing: Bool
    let palette: Palette
    let size: CGFloat

    var body: some View {
        HStack(spacing: size * 0.5) {
            Button(intent: PreviousTrackIntent()) { icon("backward.fill", big: false) }
            Button(intent: TogglePlaybackIntent()) { icon(playing ? "pause.fill" : "play.fill", big: true) }
            Button(intent: NextTrackIntent()) { icon("forward.fill", big: false) }
        }
        .buttonStyle(.plain)
    }

    private func icon(_ name: String, big: Bool) -> some View {
        let d = big ? size : size * 0.8
        return Image(systemName: name)
            .font(.system(size: d * (big ? 0.4 : 0.38), weight: .semibold))
            .foregroundColor(big ? palette.playIcon : palette.text)
            .frame(width: d, height: d)
            .background(Circle().fill(big ? palette.playFill : palette.button))
    }
}

struct PlatterWidgetView: View {
    let entry: DeckEntry
    var familyOverride: WidgetFamily?   // for rendering previews outside WidgetKit
    var monoOverride = false
    @Environment(\.widgetFamily) private var environmentFamily
    @Environment(\.widgetRenderingMode) private var renderingMode
    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    var body: some View {
        let mono = monoOverride || renderingMode != .fullColor
        let palette = mono ? Palette.monochrome : Palette.make(entry.skin, art: entry.state.artNSColor)
        GeometryReader { g in
            switch family {
            case .systemSmall:
                // Just the turntable and the song; click the record to play/pause.
                let s = min(g.size.width / Deck.size.width, (g.size.height - 30) / Deck.size.height)
                VStack(spacing: 2) {
                    ScaledDeck(entry: entry, palette: palette, scale: s)
                    TrackText(state: entry.state, palette: palette, titleSize: 11.5).padding(.horizontal, 14)
                }
                .frame(width: g.size.width, height: g.size.height)
            case .systemMedium:
                let s = g.size.height / Deck.size.height
                HStack(spacing: 4) {
                    ScaledDeck(entry: entry, palette: palette, scale: s)
                    VStack(alignment: .leading, spacing: 0) {
                        TrackText(state: entry.state, palette: palette, titleSize: 13)
                        Spacer(minLength: 6)
                        WidgetProgress(state: entry.state, date: entry.date, palette: palette)
                        Spacer(minLength: 6)
                        WidgetControls(playing: entry.state.playing, palette: palette, size: 36)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 18)
                    .padding(.trailing, 18)
                }
            default:
                // The deck takes what the song info and controls leave over.
                let s = min(g.size.width / Deck.size.width, (g.size.height - 138) / Deck.size.height)
                VStack(spacing: 0) {
                    ScaledDeck(entry: entry, palette: palette, scale: s)
                        .padding(.top, 4)
                        .frame(maxWidth: .infinity)
                    VStack(spacing: 0) {
                        TrackText(state: entry.state, palette: palette, titleSize: 15)
                        Spacer(minLength: 8)
                        WidgetProgress(state: entry.state, date: entry.date, palette: palette)
                        Spacer(minLength: 8)
                        WidgetControls(playing: entry.state.playing, palette: palette, size: 42)
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 18)
                }
            }
        }
        .unredacted()
        .widgetURL(URL(string: "platter://fullscreen"))   // clicking anywhere but the buttons
        .containerBackground(for: .widget) {
            PlinthBackground(palette: palette, shape: Rectangle())
        }
    }
}

struct PlatterWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "Platter", intent: PlatterConfig.self, provider: DeckProvider()) { entry in
            PlatterWidgetView(entry: entry)
        }
        .configurationDisplayName("Platter")
        .description("A turntable that plays along with your music.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

@main
struct PlatterWidgets: WidgetBundle {
    var body: some Widget { PlatterWidget() }
}
