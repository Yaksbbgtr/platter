// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Vorssaint's Now Playing adapter
// (https://github.com/vorssaint/vorssaint-utils, Sources/NowPlayingAdapter, Copyright (C) 2026 Vorssaint).
//
// Since macOS 15.4, MediaRemote only answers processes with Apple's own signature.
// /usr/bin/perl is a platform binary, so Resources/now-playing.pl loads this library
// into perl and calls `platter_now_playing_watch`. It prints one JSON line whenever
// the system Now Playing session changes, and reads playback commands from stdin
// ("toggle", "next", "previous", "seek <seconds>"). Closing stdin ends the process.

import AppKit
import Foundation

private typealias InfoCallback = @convention(block) (NSDictionary?) -> Void
private typealias InfoFunction = @convention(c) (DispatchQueue, @escaping InfoCallback) -> Void
private typealias BoolCallback = @convention(block) (Bool) -> Void
private typealias BoolFunction = @convention(c) (DispatchQueue, @escaping BoolCallback) -> Void
private typealias StringCallback = @convention(block) (NSString?) -> Void
private typealias StringFunction = @convention(c) (DispatchQueue, @escaping StringCallback) -> Void
private typealias RegisterFunction = @convention(c) (DispatchQueue) -> Void
private typealias SendFunction = @convention(c) (Int32, CFDictionary?) -> Bool

private let mediaRemote = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
private func symbol<T>(_ name: String, as type: T.Type) -> T? {
    guard let mediaRemote, let s = dlsym(mediaRemote, name) else { return nil }
    return unsafeBitCast(s, to: type)
}
private func constant(_ name: String) -> String? {
    guard let mediaRemote, let p = dlsym(mediaRemote, name) else { return nil }
    return p.assumingMemoryBound(to: CFString?.self).pointee.map { $0 as String }
}

private let maximumArtworkBytes = 12 * 1_024 * 1_024
private var previousArtwork: Data?
private let outputLock = NSLock()

/// JSONSerialization raises on NaN/infinity (live streams can report either), so drop those.
private func emit(_ reply: [String: Any]) {
    let finite = reply.filter { ($0.value as? Double)?.isFinite != false }
    guard JSONSerialization.isValidJSONObject(finite), let data = try? JSONSerialization.data(withJSONObject: finite) else { return }
    outputLock.lock(); defer { outputLock.unlock() }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func readNowPlaying() {
    guard let getInfo = symbol("MRMediaRemoteGetNowPlayingInfo", as: InfoFunction.self) else {
        emit(["error": "MRMediaRemoteGetNowPlayingInfo unavailable"]); return
    }
    let queue = DispatchQueue(label: "platter.now-playing.read")
    let group = DispatchGroup(), lock = NSLock()
    var reply: [String: Any] = [:]
    func set(_ key: String, _ value: Any?) { guard let value else { return }; lock.lock(); reply[key] = value; lock.unlock() }

    group.enter()
    getInfo(queue) { info in
        let i = (info as? [String: Any]) ?? [:]
        set("title", i["kMRMediaRemoteNowPlayingInfoTitle"] as? String)
        set("artist", i["kMRMediaRemoteNowPlayingInfoArtist"] as? String)
        set("album", i["kMRMediaRemoteNowPlayingInfoAlbum"] as? String)
        set("duration", (i["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue)
        let rate = (i["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
        set("rate", rate)
        if var elapsed = (i["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue {
            // The sample was taken at Timestamp; carry it forward to now.
            if rate > 0, let stamp = i["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date {
                elapsed += max(0, Date().timeIntervalSince(stamp)) * rate
            }
            set("elapsed", elapsed)
        }
        let artwork = i["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
        if let artwork, !artwork.isEmpty {
            if artwork != previousArtwork, artwork.count <= maximumArtworkBytes { set("artwork", artwork.base64EncodedString()) }
        } else {
            set("noArtwork", true)
        }
        previousArtwork = artwork
        group.leave()
    }
    if let isPlaying = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: BoolFunction.self) {
        group.enter(); isPlaying(queue) { set("playing", $0); group.leave() }
    }
    if let displayID = symbol("MRMediaRemoteGetNowPlayingApplicationDisplayID", as: StringFunction.self) {
        group.enter(); displayID(queue) { set("bundleID", $0 as String?); group.leave() }
    }
    guard group.wait(timeout: .now() + 2) == .success else { emit(["error": "metadata timeout"]); return }
    lock.lock(); let snapshot = reply; lock.unlock()
    emit(snapshot)
}

private func send(_ line: String) {
    guard let sendCommand = symbol("MRMediaRemoteSendCommand", as: SendFunction.self) else { emit(["sent": false]); return }
    let parts = line.split(separator: " ")
    var options: CFDictionary?
    let id: Int32
    switch parts.first {
    case "toggle": id = 2
    case "play": id = 0
    case "pause": id = 1
    case "next": id = 4
    case "previous": id = 5
    case "seek":
        guard parts.count == 2, let seconds = Double(parts[1]), let key = constant("kMRMediaRemoteOptionPlaybackPosition") else { return }
        id = 24; options = [key: seconds] as CFDictionary
    default: return
    }
    emit(["sent": sendCommand(id, options)])
}

@_cdecl("platter_now_playing_get")
public func platterNowPlayingGet() { readNowPlaying() }

@_cdecl("platter_now_playing_watch")
public func platterNowPlayingWatch() {
    guard let register = symbol("MRMediaRemoteRegisterForNowPlayingNotifications", as: RegisterFunction.self) else {
        emit(["error": "notifications unavailable"]); return
    }
    register(.main)
    let reader = DispatchQueue(label: "platter.now-playing.watch")
    var pending: DispatchWorkItem?
    func refresh(after delay: Double = 0.12) {
        pending?.cancel()
        let work = DispatchWorkItem { readNowPlaying() }
        pending = work
        reader.asyncAfter(deadline: .now() + delay, execute: work)
    }
    let names = ["kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                 "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                 "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                 "kMRMediaRemotePlayerNowPlayingInfoDidChangeNotification",
                 "kMRMediaRemoteNowPlayingPlayerStateDidChange",
                 "kMRMediaRemotePlayerIsPlayingDidChangeNotification"]
    let observers = names.map { name in
        NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in refresh() }
    }
    let quit = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                                  object: nil, queue: .main) { _ in refresh() }
    // Some players never post change notifications for position; a slow heartbeat keeps the timeline honest.
    let heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in refresh(after: 0) }
    var buffer = Data()
    FileHandle.standardInput.readabilityHandler = { handle in
        let data = handle.availableData
        if data.isEmpty { exit(0) }   // the app went away
        DispatchQueue.main.async {
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                reader.async { send(line); }
                refresh(after: 0.3)
            }
        }
    }
    reader.async { readNowPlaying() }
    withExtendedLifetime((observers, quit, heartbeat)) { RunLoop.main.run() }
}
