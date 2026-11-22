// SPDX-License-Identifier: GPL-3.0-or-later
// The Customize window: fonts, colours and sizes, with a live preview.

import AppKit
import SwiftUI

final class CustomizeController {
    private let np: NowPlaying, spinner: Spinner, settings: Settings
    private var window: NSWindow?

    init(np: NowPlaying, spinner: Spinner, settings: Settings) { self.np = np; self.spinner = spinner; self.settings = settings }

    func open() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Customize Platter"
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 780, height: 480)
            w.contentView = NSHostingView(rootView: CustomizeView(np: np, spinner: spinner, settings: settings))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct CustomizeView: View {
    @ObservedObject var np: NowPlaying
    @ObservedObject var spinner: Spinner
    @ObservedObject var settings: Settings
    @StateObject private var previewUI = Interaction()
    private static let families = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }

    var body: some View {
        HStack(spacing: 0) {
            preview
            Divider()
            Form {
                Section("Style") {
                    Picker("Plinth", selection: $settings.skin) { ForEach(Skin.allCases, id: \.self) { Text($0.title).tag($0) } }
                    if settings.skin == .custom {
                        ColorRow(title: "Plinth color", hex: Binding(get: { settings.style.plinth }, set: { settings.style.plinth = $0 ?? Style().plinth }),
                                 presets: ["2F5D62", "1F3A5F", "5B2A86", "8C2F39", "C8553D", "D9A441", "4F6D3A", "E7D8C9", "B8C0CC", "202024"], automatic: nil)
                    }
                }
                Section("Font") {
                    Picker("Font", selection: $settings.style.font) {
                        ForEach(Style.builtInFonts, id: \.0) { Text($0.1).tag($0.0) }
                        Divider()
                        ForEach(Style.featuredFonts.filter(Self.families.contains), id: \.self) { Text($0).font(.custom($0, size: 13)).tag($0) }
                        Divider()
                        ForEach(Self.families.filter { !Style.featuredFonts.contains($0) }, id: \.self) { Text($0).tag($0) }
                    }
                    Text("Golden Hour Static — 3:45").font(settings.style.font(19, .semibold)).foregroundStyle(.secondary)
                }
                Section("Colors") {
                    ColorRow(title: "Buttons & progress", hex: $settings.style.accent,
                             presets: ["F0A54A", "FF5A4E", "FF4FA3", "B86BFF", "4F8DFF", "25C2A0", "8BD450", "FFFFFF"], automatic: "From the album art")
                    ColorRow(title: "Text", hex: $settings.style.text,
                             presets: ["FFFFFF", "F4E6D0", "FFD166", "9AE6FF", "FFB3D1", "C7F5B5", "222222"], automatic: "From the plinth")
                    ColorRow(title: "Record", hex: $settings.style.vinyl,
                             presets: ["C1121F", "E85D04", "F2C14E", "2D6A4F", "1D4E89", "6A4C93", "EFE9E1", "FF8FAB"], automatic: "Black")
                    ColorRow(title: "Tonearm & platter", hex: $settings.style.metal,
                             presets: ["D4AF37", "B76E79", "B87333", "C0C4C8", "3A3A3E", "7FA7C9"], automatic: "Silver")
                }
                Section("Sizes") {
                    SizeRow("Text", $settings.style.textSize, Style.textRange)
                    SizeRow("Buttons", $settings.style.buttonSize, Style.buttonRange)
                    SizeRow("Progress bar", $settings.style.barSize, Style.barRange)
                    SizeRow("Album art on the record", $settings.style.labelSize, Style.labelRange)
                    SizeRow("Floating turntable", $settings.scale, Settings.scaleRange)
                    SizeRow("Full-screen turntable", $settings.style.fullScreenDeck, Style.deckRange)
                }
                Section {
                    Text("Fonts and sizes also apply to the desktop widget. When macOS shows widgets in clear or monochrome style it removes their colors; to see yours there, choose System Settings → Desktop & Dock → Widget style → Full-color.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Reset Font, Colors and Sizes") { settings.style = Style(); settings.scale = 1 }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 420)
        }
    }

    private var preview: some View {
        let card = FloatingWidget.cardSize(settings.layout, settings.style)
        return GeometryReader { g in
            let s = min((g.size.width - 8) / (card.width + 56), (g.size.height - 8) / (card.height + 56), 1.15)
            FloatingWidget(np: np, spinner: spinner, settings: settings, ui: previewUI, interactive: false)
                .scaleEffect(s)
                .frame(width: g.size.width, height: g.size.height)
                .allowsHitTesting(false)
        }
        .frame(width: 360)
        .background(LinearGradient(colors: [Color(white: 0.5), Color(white: 0.3)], startPoint: .top, endPoint: .bottom))
    }
}

struct SizeRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    init(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) { self.title = title; _value = value; self.range = range }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: $value, in: range).frame(width: 150).labelsHidden()
                Text("\(Int((value * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
                Button { value = 1 } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless).help("Standard size").disabled(abs(value - 1) < 0.005)
            }
        }
    }
}

/// Automatic (if there is one), a few ready-made colours, or any colour from the picker.
struct ColorRow: View {
    let title: String
    @Binding var hex: String?
    let presets: [String]
    let automatic: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                if let automatic {
                    Button(hex == nil ? "✓ \(automatic)" : automatic) { hex = nil }.controlSize(.small).disabled(hex == nil)
                }
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: NSColor(hex: hex ?? presets[0]) ?? .gray) },
                    set: { hex = NSColor($0).hex }), supportsOpacity: false).labelsHidden()
            }
            HStack(spacing: 8) {
                ForEach(presets, id: \.self) { p in
                    Button { hex = p } label: {
                        Circle().fill(Color(nsColor: NSColor(hex: p) ?? .gray)).frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(hex == p ? 0.9 : 0.2), lineWidth: hex == p ? 2.5 : 1))
                    }
                    .buttonStyle(.plain).accessibilityLabel(p)
                }
            }
        }
    }
}
