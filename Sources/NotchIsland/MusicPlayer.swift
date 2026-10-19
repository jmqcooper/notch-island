import AppKit

enum MusicSource: String, CaseIterable {
    case spotify
    case music

    var bundleID: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .music: return "com.apple.Music"
        }
    }

    var name: String {
        switch self {
        case .spotify: return "Spotify"
        case .music: return "Music"
        }
    }

    /// Both apps broadcast playback changes, so track info works even before
    /// Automation permission is granted.
    var notification: Notification.Name {
        switch self {
        case .spotify: return Notification.Name("com.spotify.client.PlaybackStateChanged")
        case .music: return Notification.Name("com.apple.Music.playerInfo")
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Returns {state, name, artist, album, duration, position[, artwork url]}.
    var stateScript: String {
        switch self {
        case .spotify:
            return """
            with timeout of 3 seconds
                tell application id "com.spotify.client"
                    set s to player state as text
                    if s is "stopped" then return {s}
                    set t to current track
                    return {s, name of t, artist of t, album of t, (duration of t) / 1000, player position, artwork url of t}
                end tell
            end timeout
            """
        case .music:
            return """
            with timeout of 3 seconds
                tell application id "com.apple.Music"
                    try
                        set s to player state as text
                        if s is "stopped" then return {s}
                        set t to current track
                        set d to 0
                        try
                            set d to duration of t
                        end try
                        return {s, name of t, artist of t, album of t, d, player position}
                    on error
                        return {"stopped"}
                    end try
                end tell
            end timeout
            """
        }
    }
}

struct Track: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double?

    var key: String { "\(title)\u{1F}\(artist)\u{1F}\(album)" }
}

@MainActor
final class MusicPlayer: ObservableObject {
    @Published private(set) var source: MusicSource?
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?

    private var position: Double = 0
    private var positionDate = Date()
    private var artworkKey: String?
    private var permissions: [MusicSource: Bool] = [:]
    private var pendingPermission: Set<MusicSource> = []

    init() {
        for source in MusicSource.allCases {
            DistributedNotificationCenter.default().addObserver(
                forName: source.notification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let info = note.userInfo ?? [:]
                MainActor.assumeIsolated { self?.received(info, from: source) }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, bundleID == self.source?.bundleID else { return }
                self.clear()
            }
        }
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    func position(at date: Date) -> Double {
        let elapsed = isPlaying ? date.timeIntervalSince(positionDate) : 0
        let value = position + elapsed
        if let duration = track?.duration, duration > 0 { return min(value, duration) }
        return value
    }

    // MARK: Controls

    func playPause() {
        guard let source, source.isRunning else {
            startPlayback()
            return
        }
        position = position(at: Date())
        positionDate = Date()
        isPlaying.toggle()
        send("playpause")
    }

    func next() { send("next track") }
    func previous() { send("previous track") }

    func seek(to seconds: Double) {
        position = seconds
        positionDate = Date()
        send("set player position to \(Int(seconds))")
    }

    /// Re-reads the player state. Only scripts apps that are already running,
    /// so it never launches Spotify or Music.
    func refresh() {
        let sources = source.map { [$0] } ?? MusicSource.allCases
        for source in sources where source.isRunning {
            refresh(source)
        }
    }

    // MARK: Private

    private func send(_ command: String) {
        guard let source, source.isRunning else { return }
        withPermission(for: source) {
            AppleScript.run("tell application id \"\(source.bundleID)\" to \(command)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.refresh(source) }
        }
    }

    /// Nothing playing yet: open Spotify (or Music when Spotify isn't installed) and press play.
    private func startPlayback() {
        let spotify = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MusicSource.spotify.bundleID)
        let target: MusicSource = spotify != nil ? .spotify : .music
        let play = { [weak self] in
            self?.withPermission(for: target) {
                AppleScript.run("tell application id \"\(target.bundleID)\" to play")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh(target) }
            }
        }
        if target.isRunning {
            play()
            return
        }
        guard let url = spotify ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            // Give the player a moment to load its last session before asking it to play.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { play() }
        }
    }

    /// Asks for Automation access off the main thread, so the consent prompt never freezes the island.
    private func withPermission(for source: MusicSource, _ body: @escaping () -> Void) {
        switch permissions[source] {
        case true?:
            body()
        case false?:
            return
        case nil:
            guard !pendingPermission.contains(source) else { return }
            pendingPermission.insert(source)
            let bundleID = source.bundleID
            DispatchQueue.global(qos: .userInitiated).async {
                let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
                let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), true)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.pendingPermission.remove(source)
                        switch status {
                        case noErr:
                            self.permissions[source] = true
                            Log.write("Automation access to \(source.name) granted")
                            body()
                        case OSStatus(errAEEventNotPermitted):
                            self.permissions[source] = false
                            Log.write("Automation access to \(source.name) was denied")
                        default:
                            // Usually procNotFound: the player quit. Ask again next time.
                            Log.write("Automation check for \(source.name) returned \(status)")
                        }
                    }
                }
            }
        }
    }

    private func received(_ info: [AnyHashable: Any], from source: MusicSource) {
        let state = (info["Player State"] as? String)?.lowercased() ?? ""
        if state == "stopped" {
            if self.source == source { clear() }
            return
        }
        let playing = state == "playing"
        // A paused player should not take over from one that is playing.
        if let current = self.source, current != source, isPlaying, !playing { return }

        self.source = source
        position = position(at: Date())
        positionDate = Date()
        isPlaying = playing
        if let title = info["Name"] as? String {
            let milliseconds = (info["Duration"] as? NSNumber) ?? (info["Total Time"] as? NSNumber)
            track = Track(
                title: title,
                artist: info["Artist"] as? String ?? "",
                album: info["Album"] as? String ?? "",
                duration: milliseconds.map { $0.doubleValue / 1000 }
            )
        }
        if let seconds = info["Playback Position"] as? NSNumber {
            position = seconds.doubleValue
            positionDate = Date()
        }
        refresh(source)
    }

    private func refresh(_ source: MusicSource) {
        withPermission(for: source) { [weak self] in self?.readState(of: source) }
    }

    private func readState(of source: MusicSource) {
        guard let result = AppleScript.run(source.stateScript) else { return }
        let state = result.atIndex(1)?.stringValue ?? "stopped"
        guard state != "stopped", result.numberOfItems >= 6 else {
            if self.source == source { clear() }
            return
        }
        let playing = state == "playing"
        if let current = self.source, current != source, isPlaying, !playing { return }

        self.source = source
        isPlaying = playing
        let duration = result.atIndex(5)?.doubleValue ?? 0
        let track = Track(
            title: result.atIndex(2)?.stringValue ?? "",
            artist: result.atIndex(3)?.stringValue ?? "",
            album: result.atIndex(4)?.stringValue ?? "",
            duration: duration > 0 ? duration : nil
        )
        self.track = track
        position = result.atIndex(6)?.doubleValue ?? 0
        positionDate = Date()
        let artworkURL = result.numberOfItems >= 7 ? result.atIndex(7)?.stringValue.flatMap(URL.init(string:)) : nil
        loadArtwork(for: track, from: source, url: artworkURL)
    }

    private func loadArtwork(for track: Track, from source: MusicSource, url: URL?) {
        let key = "\(source.rawValue)\u{1F}\(track.key)"
        guard key != artworkKey else { return }
        artworkKey = key
        artwork = nil

        switch source {
        case .spotify:
            guard let url else { return }
            Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
                let image = NSImage(data: data)
                await MainActor.run {
                    guard let self, self.artworkKey == key else { return }
                    self.artwork = image
                }
            }
        case .music:
            let script = """
            with timeout of 3 seconds
                tell application id "com.apple.Music"
                    try
                        return raw data of artwork 1 of current track
                    end try
                end tell
            end timeout
            """
            artwork = AppleScript.run(script).flatMap { NSImage(data: $0.data) }
        }
    }

    private func clear() {
        source = nil
        track = nil
        isPlaying = false
        artwork = nil
        artworkKey = nil
        position = 0
    }
}

@MainActor
enum AppleScript {
    /// NSAppleScript is main-thread only; every script here carries a short timeout.
    @discardableResult
    static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            Log.write(" AppleScript error\(error)")
            return nil
        }
        return result
    }
}
