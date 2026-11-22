// SPDX-License-Identifier: GPL-3.0-or-later
// Platter for iPhone: a full-screen turntable for whatever the Music app is playing. iOS doesn't let
// apps see what other apps (Spotify, YouTube…) play, so it follows Apple Music only.

import MediaPlayer
import SwiftUI

final class NowPlaying: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var playing = false
    @Published var duration: Double = 0
    @Published var artwork: UIImage?
    @Published var artColor: UIColor?
    @Published var source: String?
    @Published var denied = false
    @Published var position: Double = 0
    private var positionDate = Date()
    private let player = MPMusicPlayerController.systemMusicPlayer
    private var timer: Timer?
    private var itemKey = ""

    var hasTrack: Bool { source != nil && (!title.isEmpty || duration > 0) }
    var idleHint: String {
        denied ? "Allow access in Settings → Apps → Platter → Media & Apple Music" : "Play something in Music"
    }

    func live(at date: Date = Date()) -> Double {
        let p = position + (playing ? date.timeIntervalSince(positionDate) : 0)
        return duration > 0 ? min(duration, max(0, p)) : max(0, p)
    }
    private func setPosition(_ p: Double) { position = p; positionDate = Date() }

    func start() {
        MPMediaLibrary.requestAuthorization { status in
            DispatchQueue.main.async { if status == .authorized { self.observe() } else { self.denied = true } }
        }
    }

    private func observe() {
        guard timer == nil else { return }
        denied = false
        player.beginGeneratingPlaybackNotifications()
        for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange, .MPMusicPlayerControllerPlaybackStateDidChange,
                     UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        }
        // Seeking in Music posts no notification, so check in now and then.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    private func refresh() {
        guard let item = player.nowPlayingItem else {
            if source != nil { source = nil; title = ""; artist = ""; album = ""; playing = false; duration = 0; setPosition(0); setArtwork(nil); itemKey = "" }
            return
        }
        let isPlaying = player.playbackState == .playing
        let time = player.currentPlaybackTime
        if time.isFinite, isPlaying != playing || abs(time - live()) > 0.75 { setPosition(time) }
        if playing != isPlaying { playing = isPlaying }
        let key = "\(item.persistentID)|\(item.playbackStoreID)|\(item.title ?? "")"
        if key != itemKey {
            itemKey = key
            source = "Music"
            title = item.title ?? ""; artist = item.artist ?? ""; album = item.albumTitle ?? ""
            duration = item.playbackDuration
            setPosition(time.isFinite ? time : 0)
            setArtwork(nil)
        }
        // Streamed songs can get their artwork a moment after they start.
        if artwork == nil, let image = item.artwork?.image(at: CGSize(width: 800, height: 800)) { setArtwork(image) }
    }

    private func setArtwork(_ image: UIImage?) { artwork = image; artColor = image.flatMap(averageColor) }

    func playPause() {
        guard hasTrack else {
            if let url = URL(string: denied ? UIApplication.openSettingsURLString : "music://") { UIApplication.shared.open(url) }
            return
        }
        setPosition(live())
        if playing { player.pause() } else { player.play() }
        playing.toggle()
    }
    func next() { if hasTrack { player.skipToNextItem() } }
    func previous() {
        guard hasTrack else { return }
        if live() > 3 { player.skipToBeginning(); setPosition(0) } else { player.skipToPreviousItem() }
    }
    func seek(_ t: Double) { setPosition(t); player.currentPlaybackTime = t }
}

struct PhoneView: View {
    @StateObject private var np = NowPlaying()
    @StateObject private var spinner = Spinner()
    @StateObject private var ui = Interaction()
    @AppStorage("skin") private var skin = Skin.walnut
    @State private var showControls = true
    @State private var touches = 0

    var body: some View {
        FullScreenPlayer(np: np, spinner: spinner, ui: ui, skin: $skin, showControls: showControls || !np.playing)
            .contentShape(Rectangle())
            .onTapGesture { showControls.toggle(); touches += 1 }
            .simultaneousGesture(DragGesture(minimumDistance: 0).onEnded { _ in touches += 1 })
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .onAppear { np.start() }
            .onChange(of: np.playing) { _, playing in
                spinner.setPlaying(playing)
                UIApplication.shared.isIdleTimerDisabled = playing   // stay awake while the record spins
                touches += 1
            }
            // Hide the controls after a few quiet seconds; every touch starts the wait again.
            .task(id: touches) {
                try? await Task.sleep(for: .seconds(6))
                if !Task.isCancelled { showControls = false }
            }
    }
}

@main
struct PlatterPhoneApp: App {
    var body: some Scene { WindowGroup { PhoneView() } }
}
