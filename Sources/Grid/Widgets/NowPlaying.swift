import AppKit
import Observation
import ScriptingBridge

/// What Apple Music or Spotify is playing, for the Now Playing widget.
///
/// Two sources, used deliberately:
/// - **Track changes** come from the players' own public distributed notifications
///   (`com.apple.Music.playerInfo`, `com.spotify.client.PlaybackStateChanged`). Reading them needs
///   no permission and sends nothing anywhere.
/// - **Controls, artwork and the playback position** use Apple Events (Scripting Bridge, no
///   script text), which macOS gates behind a per-app Automation prompt ("GRID wants to control
///   Music"). GRID asks only when you press Connect or a control, never at launch, and never
///   launches a player that isn't running (every event checks first).
///
/// Other sources (a video in a browser, podcasts) would need the private MediaRemote framework,
/// which macOS 15.4 and later reserve for Apple's own apps, so they aren't shown.
@Observable
@MainActor
final class NowPlaying {
    enum Player: String, CaseIterable, Sendable {
        case music = "com.apple.Music"
        case spotify = "com.spotify.client"
        var name: String { self == .music ? "Music" : "Spotify" }
        var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).isEmpty }
    }

    enum Access: Equatable { case unknown, needsConsent, granted, denied, notRunning }

    struct Track: Equatable, Sendable {
        var id: String
        var title: String
        var artist: String
        var album: String
        var duration: Double?   // seconds
    }

    fileprivate(set) var player: Player?
    fileprivate(set) var track: Track?
    fileprivate(set) var playing = false
    /// Position (seconds) at `positionAt`; extrapolated while playing.
    fileprivate(set) var position: Double?
    fileprivate(set) var positionAt = Date()
    fileprivate(set) var artwork: ArtMatrix?
    private(set) var access: [Player: Access] = [:]
    /// Which player to follow: nil = whichever is playing (Music first).
    var preferred: Player? { didSet { if oldValue != preferred { refresh() } } }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored fileprivate var artworkFor: String?
    @ObservationIgnored private var resync: Task<Void, Never>?
    @ObservationIgnored private let bridge = PlayerBridge()

    var isActive: Bool { !observers.isEmpty }

    /// Current position, extrapolated from the last report while playing.
    func position(at date: Date) -> Double? {
        guard let position else { return nil }
        let p = playing ? position + date.timeIntervalSince(positionAt) : position
        if let d = track?.duration, d > 0 { return min(max(p, 0), d) }
        return max(p, 0)
    }

    // MARK: Lifecycle (only listens while a Now Playing widget exists)

    func setActive(_ on: Bool) {
        guard on != isActive else { return }
        if on {
            let dnc = DistributedNotificationCenter.default()
            for p in Player.allCases {
                let name = Notification.Name(p == .music ? "com.apple.Music.playerInfo" : "com.spotify.client.PlaybackStateChanged")
                observers.append(dnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                    let info = PlayerInfo(n.userInfo)
                    MainActor.assumeIsolated { self?.received(info, from: p) }
                })
            }
            let ws = NSWorkspace.shared.notificationCenter
            for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                observers.append(ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] note in
                    let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                    MainActor.assumeIsolated {
                        guard let self, let id, Player(rawValue: id) != nil else { return }
                        self.refresh()
                    }
                })
            }
            refresh()
        } else {
            observers.forEach {
                DistributedNotificationCenter.default().removeObserver($0)
                NSWorkspace.shared.notificationCenter.removeObserver($0)
            }
            observers = []
            resync?.cancel(); resync = nil
            player = nil; track = nil; playing = false; position = nil; artwork = nil; artworkFor = nil
        }
    }

    // MARK: Notifications

    private func received(_ info: PlayerInfo, from p: Player) {
        // Follow the preferred player only; otherwise the one that is playing (a paused player
        // doesn't take over from one that is playing).
        if let preferred, preferred != p { return }
        if preferred == nil, let player, player != p, playing, !info.playing { return }
        if info.stopped {
            if player == p { clear(keeping: p) }
            return
        }
        player = p
        playing = info.playing
        if let t = info.track { setTrack(t) }
        if let pos = info.position { position = pos; positionAt = Date() }
        else if access[p] == .granted { syncPosition() }
        else if !info.playing, let pos = position(at: Date()) { position = pos; positionAt = Date() }
        loadArtworkIfNeeded()
        keepPositionInSync()
    }

    fileprivate func clear(keeping p: Player) {
        player = p; track = nil; playing = false; position = nil; artwork = nil; artworkFor = nil
    }

    fileprivate func setTrack(_ t: Track) {
        if track?.id != t.id || track?.title != t.title {
            artwork = nil
            artworkFor = nil
            if position == nil || track != nil { position = 0; positionAt = Date() }
        }
        track = t
    }

    // MARK: Apple Events

    /// Re-reads permission and, when allowed, the current state of a running player.
    func refresh() {
        let candidates = preferred.map { [$0] } ?? Player.allCases
        Task {
            var states: [(Player, Access, PlayerState?)] = []
            for p in candidates {
                let a = await bridge.access(p, ask: false)
                let s = a == .granted ? await bridge.state(p) : nil
                states.append((p, a, s))
            }
            for (p, a, _) in states { access[p] = a }
            let live = states.filter { $0.2 != nil }
            let pick = live.first { $0.2?.playing == true } ?? live.first { $0.0 == player } ?? live.first
            if let pick, let s = pick.2 {
                apply(s, from: pick.0)
            } else if let player, !player.isRunning {
                clear(keeping: player); self.player = nil
            }
        }
    }

    /// Asks macOS for permission to control `p` (shows the system Automation prompt once).
    func connect(_ p: Player) {
        Task {
            access[p] = await bridge.access(p, ask: true)
            refresh()
        }
    }

    func playPause() { send(.playPause) }
    func next() { send(.next) }
    func previous() { send(.previous) }

    private func send(_ c: PlayerCommand) {
        guard let p = player ?? preferred ?? Player.allCases.first(where: \.isRunning) else { return }
        Task {
            if access[p] != .granted { access[p] = await bridge.access(p, ask: true) }
            guard access[p] == .granted else { return }
            await bridge.perform(c, on: p)
            if let s = await bridge.state(p) { apply(s, from: p) }
        }
    }

    private func apply(_ s: PlayerState, from p: Player) {
        player = p
        playing = s.playing
        if let t = s.track { setTrack(t) } else { track = nil; artwork = nil; artworkFor = nil }
        if let pos = s.position { position = pos; positionAt = Date() }
        loadArtworkIfNeeded()
        keepPositionInSync()
    }

    private func syncPosition() {
        guard let p = player else { return }
        Task {
            if let s = await bridge.state(p), s.track?.id == track?.id, let pos = s.position {
                position = pos; positionAt = Date(); playing = s.playing
            }
        }
    }

    /// While playing, re-reads the position every 15 s (seeking posts no notification).
    private func keepPositionInSync() {
        resync?.cancel()
        guard playing, let p = player, access[p] == .granted else { resync = nil; return }
        resync = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self?.syncPosition()
            }
        }
    }

    private func loadArtworkIfNeeded() {
        guard let p = player, let t = track, artworkFor != t.id, access[p] == .granted else { return }
        artworkFor = t.id
        Task {
            let art = await bridge.artwork(p)
            guard track?.id == t.id else { return }
            artwork = art
        }
    }
}

#if DEBUG
extension NowPlaying {
    /// QA only: show a track without talking to a player.
    func debugInject(player p: Player, title: String?, artist: String, album: String, duration: Double?,
                     position pos: Double?, playing isPlaying: Bool, art: ArtMatrix?) {
        guard let title else { clear(keeping: p); return }
        player = p
        playing = isPlaying
        setTrack(Track(id: "qa:" + title, title: title, artist: artist, album: album, duration: duration))
        position = pos ?? 0; positionAt = Date()
        artworkFor = "qa:" + title
        artwork = art
    }
}
#endif

// MARK: - Notification payloads

/// The fields GRID reads from a player's notification (nothing else is kept).
struct PlayerInfo: Sendable {
    var playing = false
    var stopped = false
    var track: NowPlaying.Track?
    var position: Double?

    init(_ info: [AnyHashable: Any]?) {
        guard let info else { stopped = true; return }
        let state = info["Player State"] as? String ?? ""
        playing = state == "Playing"
        stopped = state == "Stopped"
        let title = info["Name"] as? String ?? ""
        guard !title.isEmpty else { return }
        let id = (info["PersistentID"] as? NSNumber)?.stringValue ?? info["Track ID"] as? String ?? title
        var duration: Double?
        if let ms = info["Total Time"] as? NSNumber { duration = ms.doubleValue / 1000 }      // Music
        else if let ms = info["Duration"] as? NSNumber { duration = ms.doubleValue / 1000 }   // Spotify
        track = .init(id: id, title: title, artist: info["Artist"] as? String ?? "",
                      album: info["Album"] as? String ?? "", duration: duration)
        position = (info["Playback Position"] as? NSNumber)?.doubleValue                      // Spotify only
    }
}

struct PlayerState: Sendable {
    var playing: Bool
    var track: NowPlaying.Track?
    var position: Double?
}

enum PlayerCommand: Sendable { case playPause, next, previous }

// MARK: - Scripting Bridge (one serial queue; never launches a player)

/// Talks to the players through Scripting Bridge on its own queue, so a slow or hung player never
/// stalls the UI. Every call first checks that the player is running: an Apple Event sent to an
/// app that isn't would launch it.
final class PlayerBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "grid.nowplaying", qos: .userInitiated)
    private var apps: [String: SBApplication] = [:]
    /// Only Spotify's own image CDN is fetched (for Spotify artwork); no cookies or cache.
    private let session = URLSession(configuration: .ephemeral)

    private func app(_ p: NowPlaying.Player) -> SBApplication? {
        guard p.isRunning else { return nil }
        if let a = apps[p.rawValue] { return a }
        guard let a = SBApplication(bundleIdentifier: p.rawValue) else { return nil }
        a.timeout = 120   // ticks (2 s): a busy player must not hold the queue for the default 2 min
        apps[p.rawValue] = a
        return a
    }

    private func run<T: Sendable>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { c in queue.async { c.resume(returning: body()) } }
    }

    func access(_ p: NowPlaying.Player, ask: Bool) async -> NowPlaying.Access {
        await run {
            guard p.isRunning else { return .notRunning }
            let target = NSAppleEventDescriptor(bundleIdentifier: p.rawValue)
            guard let desc = target.aeDesc else { return .unknown }
            switch AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask) {
            case noErr: return .granted
            case OSStatus(errAEEventNotPermitted): return .denied
            case OSStatus(errAEEventWouldRequireUserConsent): return .needsConsent
            case OSStatus(procNotFound): return .notRunning
            default: return .unknown
            }
        }
    }

    func perform(_ c: PlayerCommand, on p: NowPlaying.Player) async {
        await run { [self] in
            guard let a = app(p) else { return }
            let sel: String
            switch c {
            case .playPause: sel = "playpause"
            case .next: sel = "nextTrack"
            case .previous: sel = p == .music ? "backTrack" : "previousTrack"
            }
            let s = NSSelectorFromString(sel)
            if a.responds(to: s) { _ = a.perform(s) }
        }
    }

    func state(_ p: NowPlaying.Player) async -> PlayerState? {
        await run { [self] in
            guard let a = app(p) else { return nil }
            // playerState is an enum code: 'kPSP' playing, 'kPSp' paused, 'kPSS' stopped.
            guard let code = (a.value(forKey: "playerState") as? NSNumber)?.uint32Value else { return nil }
            let playing = code == 0x6B50_5350
            if code == 0x6B50_5353 { return PlayerState(playing: false, track: nil, position: nil) }
            var track: NowPlaying.Track?
            if let t = a.value(forKey: "currentTrack") as? SBObject, let title = t.value(forKey: "name") as? String, !title.isEmpty {
                let id = (t.value(forKey: p == .music ? "persistentID" : "id") as? String) ?? title
                var duration = (t.value(forKey: "duration") as? NSNumber)?.doubleValue
                if p == .spotify, let d = duration { duration = d / 1000 }   // Spotify reports ms
                track = .init(id: id, title: title, artist: t.value(forKey: "artist") as? String ?? "",
                              album: t.value(forKey: "album") as? String ?? "", duration: duration)
            }
            let pos = (a.value(forKey: "playerPosition") as? NSNumber)?.doubleValue
            return PlayerState(playing: playing, track: track, position: pos)
        }
    }

    func artwork(_ p: NowPlaying.Player) async -> ArtMatrix? {
        switch p {
        case .music:
            return await run { [self] in
                guard let a = app(p), let t = a.value(forKey: "currentTrack") as? SBObject,
                      let arts = t.value(forKey: "artworks") as? SBElementArray,
                      let first = arts.firstObject as? SBObject else { return nil }
                if let img = first.value(forKey: "data") as? NSImage,
                   let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) { return ArtMatrix(cg) }
                if let raw = first.value(forKey: "rawData") as? Data, let img = NSImage(data: raw),
                   let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) { return ArtMatrix(cg) }
                return nil
            }
        case .spotify:
            let link: String? = await run { [self] in
                guard let a = app(p), let t = a.value(forKey: "currentTrack") as? SBObject else { return nil }
                return t.value(forKey: "artworkUrl") as? String
            }
            guard let link, let url = URL(string: link), url.scheme == "https",
                  url.host == "i.scdn.co" || url.host?.hasSuffix(".scdn.co") == true else { return nil }
            var req = URLRequest(url: url, timeoutInterval: 8)
            req.httpShouldHandleCookies = false
            guard let (data, _) = try? await session.data(for: req), data.count < 4_000_000,
                  let img = NSImage(data: data), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            return ArtMatrix(cg)
        }
    }
}

// MARK: - Artwork as a luminance grid

/// Cover art reduced to a small grid of brightness values, so the widget can redraw it in GRID's
/// own colours (dot matrix or scan lines) instead of showing the photo. The image itself isn't kept.
struct ArtMatrix: Equatable, Sendable {
    static let size = 40
    let values: [UInt8]   // size × size, row-major from the top, 0 = black

    init?(_ image: CGImage) {
        let n = Self.size
        var px = [UInt8](repeating: 0, count: n * n)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            // Centre-crop to a square.
            let w = CGFloat(image.width), h = CGFloat(image.height), side = min(w, h)
            let scale = CGFloat(n) / side
            ctx.draw(image, in: CGRect(x: -(w - side) / 2 * scale, y: -(h - side) / 2 * scale, width: w * scale, height: h * scale))
            return true
        }
        guard ok else { return nil }
        // Equalize the histogram so dark or washed-out covers still read as shapes.
        var hist = [Int](repeating: 0, count: 256)
        for v in px { hist[Int(v)] += 1 }
        var cdf = [Int](repeating: 0, count: 256), run = 0
        for i in 0..<256 { run += hist[i]; cdf[i] = run }
        let first = cdf.first { $0 > 0 } ?? 0
        let span = max(px.count - first, 1)
        values = px.map { UInt8(max(0, cdf[Int($0)] - first) * 255 / span) }
    }

    func value(_ x: Int, _ y: Int) -> Double { Double(values[y * Self.size + x]) / 255 }
}
