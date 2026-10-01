import AVFoundation
import AVKit
import AetherEngine
import AetherEngineSMB
import Combine
import Flutter
import MediaPlayer
import UIKit

/// Wrapper view around AetherEngine's `AetherPlayerView`. Forces the engine's
/// internal `AVPlayerLayer` to relayout when Flutter resizes the platform view
/// (e.g. after device unlock / rotation). Without this, the `AVPlayerLayer`
/// keeps its initial frame and the video appears stretched until the next
/// explicit layout pass.
private final class PlayerContainerView: UIView {
    /// The engine view whose sublayers need relayout on bounds change.
    var engineView: UIView? {
        didSet {
            guard let v = engineView else { return }
            addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = true
            v.frame = bounds
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Force AetherEngine's internal AVPlayerLayer to match the new bounds.
        engineView?.layer.layoutSublayers()
    }
}

/// Subtitle overlay drawn by the host (AetherEngine decodes cues into
/// `engine.$subtitleCues`; the engine's `AetherPlayerView` does not paint them).
/// Text and bitmap cues are positioned against the aspect-fit video rect, and
/// `layoutSubviews` re-runs on rotation/resize so a cue keeps hugging the video
/// even mid-cue instead of drifting to the letterbox edge.
private final class SubtitleOverlayView: UIView {
    private let label = UILabel()
    private let imageView = UIImageView()
    /// Coded video size (points-independent) used to compute the aspect-fit rect.
    fileprivate var videoSize: CGSize = .zero
    private var activeText: String?
    private var activeImage: SubtitleImage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // The engine re-attaches the video layer on every session swap, which
        // re-adds it above sibling subviews; pinning our z-order keeps cues on top.
        layer.zPosition = 1000

        label.isHidden = true
        label.textColor = .white
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.shadowColor = .black
        label.shadowOffset = CGSize(width: 1, height: 1)
        addSubview(label)

        imageView.isHidden = true
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - User subtitle appearance

    private var verticalPosition: Int = 20

    /// Applies the user's subtitle appearance from Dart (`setSubtitleStyle`).
    /// - `size` multiplies the base glyph size.
    /// - `color` is the text ARGB; `bg` an ARGB cue-box (alpha 0 = none).
    /// - `outline` toggles the black shadow behind glyphs.
    /// - `verticalPosition` 0–255 (0 = top, 255 = bottom, default 20 = near bottom).
    func applyStyle(size: Double, color: Int, bg: Int, outline: Bool, verticalPosition: Int = 20) {
        self.verticalPosition = verticalPosition
        let base = CGFloat(17 * size.clamped(0.6...2.0))
        label.font = .systemFont(ofSize: base, weight: .semibold)
        label.textColor = UIColor(argb: color)
        if (bg >> 24) != 0 {
            label.backgroundColor = UIColor(argb: bg)
            // UIKit auto-sets UILabel.opaque = true when backgroundColor is
            // assigned, which forces the background to render opaque and
            // silently ignores the alpha byte. Turn it off so the partial
            // alpha from the ARGB value actually blends with the video.
            label.isOpaque = false
            label.layer.cornerRadius = 4
            label.clipsToBounds = true
        } else {
            label.backgroundColor = .clear
            label.layer.cornerRadius = 0
            label.clipsToBounds = false
        }
        if outline {
            label.shadowColor = .black
            label.shadowOffset = CGSize(width: 1, height: 1)
        } else {
            label.shadowColor = nil
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        positionActiveCue()
    }

    func show(text: String) {
        activeText = text.isEmpty ? nil : text
        activeImage = nil
        label.text = text
        imageView.isHidden = true
        setNeedsLayout()
    }

    func show(image: SubtitleImage) {
        activeImage = image
        activeText = nil
        imageView.image = UIImage(cgImage: image.cgImage)
        imageView.isHidden = false
        label.isHidden = true
        setNeedsLayout()
    }

    func clear() {
        activeText = nil
        activeImage = nil
        label.isHidden = true
        imageView.isHidden = true
    }

    private func positionActiveCue() {
        if let image = activeImage {
            position(image: image)
        } else if let text = activeText {
            position(text: text)
        } else {
            label.isHidden = true
            imageView.isHidden = true
        }
    }

    private func position(text: String) {
        guard !text.isEmpty else {
            label.isHidden = true
            return
        }
        label.isHidden = false
        imageView.isHidden = true
        let rect = videoRect(in: bounds)
        let maxWidth = max(rect.width - 32, 40)
        let size = label.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        let width = min(size.width, maxWidth)
        // vPos 0=bottom, 255=top (matches Android).
        let normalizedVPos = CGFloat(max(0, min(255, verticalPosition))) / 255.0
        let y = rect.maxY - size.height - (rect.height - size.height) * normalizedVPos
        label.frame = CGRect(
            x: rect.midX - width / 2,
            y: y,
            width: width,
            height: size.height
        )
    }

    private func position(image: SubtitleImage) {
        guard imageView.image != nil else { return }
        imageView.isHidden = false
        label.isHidden = true
        let rect = videoRect(in: bounds)
        let p = image.position
        // `position` is normalized [0,1] against the subtitle canvas (usually
        // the coded video). A cropped rip can carry a taller canvas than the
        // video, so map canvas -> video width-aligned and center-anchored,
        // mirroring the engine's own SubtitleFrameCompositor mapping.
        let c = image.canvasSize
        let frame = CGRect(origin: .zero, size: rect.size)
        let r: CGRect
        if c.width > 0, c.height > 0 {
            let px = p.minX * c.width
            let py = p.minY * c.height
            let scale = frame.width / c.width
            r = CGRect(
                x: px * scale,
                y: frame.height / 2 + (py - c.height / 2) * scale,
                width: p.width * c.width * scale,
                height: p.height * c.height * scale
            )
        } else {
            r = CGRect(
                x: p.minX * frame.width,
                y: p.minY * frame.height,
                width: p.width * frame.width,
                height: p.height * frame.height
            )
        }
        imageView.frame = r.offsetBy(dx: rect.minX, dy: rect.minY)
    }

    /// Aspect-fit rect of the video within the overlay's bounds.
    private func videoRect(in bounds: CGRect) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        let aspect = videoSize.width / videoSize.height
        let viewAspect = bounds.width / max(bounds.height, 1)
        if viewAspect > aspect {
            // View is wider than the video: fills the height, bars left/right.
            let w = bounds.height * aspect
            return CGRect(x: bounds.midX - w / 2, y: bounds.minY, width: w, height: bounds.height)
        } else {
            // View is taller than the video: fills the width, bars top/bottom.
            let h = bounds.width / aspect
            return CGRect(x: bounds.minX, y: bounds.midY - h / 2, width: bounds.width, height: h)
        }
    }
}

/// Factory registered for `dreamplayer/exo_player` on iOS (see AppDelegate).
final class AvPlayerViewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        // UIKit platform views are created on the platform (main) thread, so the
        // MainActor-isolated AvPlayerView init is safe to assume here.
        MainActor.assumeIsolated {
            AvPlayerView(messenger: messenger, viewId: viewId, frame: frame)
        }
    }
}

/// AetherEngine-backed platform view mirroring the Android ExoPlayer contract:
/// same channel names (`dreamplayer/exo_<id>`, `dreamplayer/exo_events_<id>`),
/// same method names, same event map keys, so the Dart `ExoPlayerController`
/// works unchanged on both platforms.
///
/// AetherEngine gives iOS what AVPlayer alone cannot: FFmpeg demux of MKV /
/// TS / AVI / WebM, DTS / DTS-HD / TrueHD / E-AC3 decode (AudioToolbox +
/// libavcodec), and real Dolby Vision / HDR10(+) via the native AVPlayer path
/// for Apple containers. Embedded and sideloaded subtitle tracks (SRT / ASS /
/// VTT sidecars auto-paired from the video's folder) are listed through the
/// same `subtitleTracks` / `selectSubtitleTrack` contract.
@MainActor
final class AvPlayerView: NSObject, FlutterPlatformView, FlutterStreamHandler {

    private let container: PlayerContainerView
    private let engineView: AetherPlayerView
    private let subtitleOverlay: SubtitleOverlayView
    private let engine: AetherEngine?

    private let methodChannel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel
    private var eventSink: FlutterEventSink?
    private var tickTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // ---- Source facts (captured from the load probe). ----
    private var videoCodecName: String?
    private var videoWidth: Int = 0
    private var videoHeight: Int = 0
    private var isDolbyVision = false
    private var dvProfile: Int?

    /// Set when the loaded file is a Dolby Vision profile this platform
    /// cannot decode, so playback is stopped with a specific reason instead of
    /// a bare "playback failed".
    ///
    /// Profile 4 is single-layer IPTPQc2: unlike P7/P8 it carries **no
    /// backward-compatible HDR10 base layer**, so there is no plain-HEVC
    /// fallback to degrade into — and AVFoundation does not decode P4 at all
    /// (Apple supports P8, and P5 on Apple Silicon). P4 is a broadcast/IPTV
    /// profile rather than a consumer-delivery one.
    private var dvUnsupportedProfile: String?

    private var lastError: String?
    private var pendingAutoSubtitleIndex: Int?
    private var savedVolume: Float = 1
    private var isMuted = false
    /// Deadline until which error emission to Dart is suppressed after an
    /// audio-track switch.  Prevents "playback failed" from flashing when
    /// the in-place switch transiently errors (e.g. during screen recording
    /// or a brief codec re-init).  If the engine recovers within the window,
    /// the error is never shown.  Cleared on the next non-audio event.
    private var audioSwitchSuppressUntil: Date = .distantPast

    // ---- Last-opened source (needed to reload when the engine parks in .ended). ----
    private var lastSource: MediaSource?
    private var lastLoadOptions = LoadOptions()
    private var lastWebDAVInfo: (url: URL, headers: [String: String], allowSelfSigned: Bool)?
    /// Pending/active FTP/SFTP uri (dreamplayer `ftp://<serverId>/<path>`),
    /// rebuilt on replay/scrub-after-end like the WebDAV source.
    private var lastFtpUri: String?

    // ---- SMB stream (see SMBBridge.openShare + SMBSource.swift). The engine
    // reads through an SMBByteRangeSource over a live SMBPlayback that
    // SMBBridge owns. We never close that session on a track switch: the demux
    // thread may still be reading it, which is the race that crashed the retired
    // AMSMB2 build. SMBBridge tears it down on closeShare instead. ----
    private var smbToken: String?
    private var isSMBStream = false
    /// A raw smb:// URI awaiting resolution inside the load Task.
    private var smbUri: String?
    private var smbServerId: String?
    /// The live SMB session backing playback. Held so a reload can build a FRESH
    /// source over the same open handle: reads are independent ranged READs, so
    /// this needs neither a reconnect nor a re-auth.
    private var smbPlayback: SMBPlayback?
    /// emit() runs several times a second, so state/error logging has to
    /// remember the last line or one event fills the log with copies.
    private var lastLoggedState: String = ""
    private var lastLoggedError: String = ""
    /// Extension carried by the token URL, handed to the engine as a probe hint.
    private var smbFormatHint: String?
    /// Lower-cased scheme of the currently-open source (e.g. "file", "http",
    /// "https", "ftp", "sftp", "dreamplayersmb", "dreamplayerwebdav"). Captured
    /// at open time so the network chip can gate between "Local" and a live
    /// speed (only http/https feed AVPlayerItemAccessLog).
    private var currentSourceScheme: String = ""

     /// Set when the app enters background; cleared on foreground.
     /// When play() is called while this is true, reload the session
     /// instead of calling play() — iOS may have revoked file handles
     /// (security-scoped bookmarks) or killed network connections during sleep.
     private var needsReloadAfterBackground = false
     /// Final URL the engine was bound to (file URL for local paths, otherwise
     /// the same URL we handed to the engine). Reserved for the
     /// source-label / chapter-probe paths; the network telemetry is gone.
     private var currentSourceURL: URL?
     /// Identity key of the file currently opened by this view. Used so that
     /// probe/HDR state survives a re-open of the SAME file (resume / replay):
     /// the engine probe can drop DV info when loading with a start position,
     /// which would regress the badge to SDR. Only cleared when a different
     /// file is opened.
     /// **Static** — survives across AvPlayerView recreations (navigating back
     /// and tapping the same card again creates a fresh instance).
     private static var lastOpenedKey: String?

    /// Subtitle cue shift from the user's appearance settings (seconds).
    /// Positive = cues appear LATER than authored.
    private var subtitleDelaySeconds: Double = 0

    /// MKV chapters parsed from the file (local + Files-app SMB). Empty when
    /// the container has none or the source is not a seekable file.
    private var chapters: [[String: Any]] = []

    /// Bitstream HDR probe results (ST 2094-40 dynamic metadata for HDR10+,
    /// static mastering/light-level for HDR10 without MKV Colour).
    private var isHdr10PlusContent = false
    private var isHdr10Content = false

    /// Volume Boost (1.0 – 3.0) and Night Mode (DRC) — persisted in UserDefaults
    /// under FlutterSharedPreferences keys so Dart and native stay in sync.
    private var audioBoost: Float = {
        let obj = UserDefaults.standard.object(forKey: "flutter.dreamplayer.audioBoost")
        let v: Double
        if let d = obj as? Double { v = d }
        else if let f = obj as? Float { v = Double(f) }
        else if let n = obj as? NSNumber { v = n.doubleValue }
        else { v = 1.0 }
        return Float(max(1.0, min(v, 3.0)))
    }()
    private var nightModeEnabled: Bool =
        UserDefaults.standard.bool(forKey: "flutter.dreamplayer.nightMode")

    // ---- Background playback: lock screen / control center ----
    /// Media title from Dart's `open` (shown on the lock screen).
    private var mediaTitle: String?
    /// Remote-command target tokens, removed in deinit.
    private var remoteCommandTokens: [Any] = []

    deinit {
        let cc = MPRemoteCommandCenter.shared()
        for token in remoteCommandTokens {
            cc.playCommand.removeTarget(token)
            cc.pauseCommand.removeTarget(token)
            cc.togglePlayPauseCommand.removeTarget(token)
            cc.changePlaybackPositionCommand.removeTarget(token)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func applyAudioBoost() {
        // AVPlayer volume is capped at 1.0; boost >1 is clamped and night mode
        // is a flag only for UI / future DRC tap. Store and emit so chips update.
        let effective: Float = min(audioBoost, 1.0)
        if !isMuted { engine?.volume = effective }
        savedVolume = effective
        emit()
    }

    

    init(messenger: FlutterBinaryMessenger, viewId: Int64, frame: CGRect) {
        let ev = AetherPlayerView(frame: frame)
        engineView = ev
        container = PlayerContainerView(frame: frame)
        container.backgroundColor = .black
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.engineView = ev
        subtitleOverlay = SubtitleOverlayView(frame: container.bounds)
        subtitleOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        engine = try? AetherEngine()
        methodChannel = FlutterMethodChannel(name: "dreamplayer/exo_\(viewId)", binaryMessenger: messenger)
        eventChannel = FlutterEventChannel(name: "dreamplayer/exo_events_\(viewId)", binaryMessenger: messenger)
        super.init()

        container.addSubview(subtitleOverlay)

        if let engine {
            engine.bind(view: ev)
            observeEngine(engine)
        }

        setupRemoteCommands()
        eventChannel.setStreamHandler(self)
        // Keep the pip auto-inline flag in sync when the Settings toggle
        // changes while a player is alive.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.pipController?.canStartPictureInPictureAutomaticallyFromInline =
                Self.pipSettingEnabled()
            // If the toggle was just turned off and a controller already
            // exists, keep it (manual pip still works via the system UI);
            // auto-inline is what the toggle gates. If turned off before
            // open, ensurePipController simply won't create one.
        }

        // Track background/foreground transitions so play() can reload
        // instead of calling play() on a potentially dead source.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.needsReloadAfterBackground = true }

        methodChannel.setMethodCallHandler { [weak self] call, result in
            Task { @MainActor in
                guard let self else {
                    result(FlutterMethodNotImplemented)
                    return
                }
                let args = call.arguments as? [String: Any]
                switch call.method {
                case "open":
                    self.open(args, result)
                case "play":
                    // .ended is terminal in AetherEngine (seek/play no-op there), so
                    // replay = reload the last source from the start.
                    if self.engine?.state == .ended {
                        await self.reloadSession(at: 0)
                    } else if self.needsReloadAfterBackground {
                        // iOS may have revoked security-scoped bookmark access
                        // or killed network connections during a background/lock
                        // period. Reload from the current position to
                        // re-establish the source instead of calling play()
                        // on a potentially dead stream.
                        self.needsReloadAfterBackground = false
                        let pos = self.engine?.currentTime ?? 0
                        await self.reloadSession(at: pos)
                    } else {
                        self.engine?.play()
                    }
                    self.emit()
                    result(nil)
                case "pause":
                    self.engine?.pause()
                    result(nil)
                case "seekTo":
                    let ms = (args?["positionMs"] as? NSNumber)?.int64Value ?? 0
                    if self.engine?.state == .ended {
                        // Pulling the scrubber back after end-of-media: reload at the
                        // requested position instead of seeking a parked session.
                        await self.reloadSession(at: Double(ms) / 1000.0)
                    } else if self.needsReloadAfterBackground {
                        self.needsReloadAfterBackground = false
                        await self.reloadSession(at: Double(ms) / 1000.0)
                    } else {
                        await self.engine?.seek(to: Double(ms) / 1000.0)
                    }
                    self.emit()
                    result(nil)
                case "setVolume":
                    let volume = (args?["volume"] as? NSNumber)?.floatValue ?? 1
                    self.savedVolume = min(max(volume, 0), 1)
                    if !self.isMuted { self.engine?.volume = self.savedVolume }
                    result(nil)
                case "setMuted":
                    self.isMuted = (args?["muted"] as? Bool) ?? false
                    self.engine?.volume = self.isMuted ? 0 : self.savedVolume
                    result(nil)
                case "getAudioTracks":
                    result(self.audioTrackMaps())
                case "getState":
                    // Push a fresh snapshot to the event stream and return the
                    // current state; Dart uses it after a background/foreground
                    // cycle to decide whether to reopen the media.
                    self.emit()
                    result(self.stateMap())
                case "setAudioTrack":
                    let index = (args?["index"] as? NSNumber)?.intValue ?? -1
                    // Dart sends the flat position (0,1,…) matching the
                    // `index` field in audioTrackMaps, just like Android.
                    // The engine's `selectAudioTrack(index:)` expects the
                    // native track `id`, so convert flat → id.
                    let trackId = self.engineAudioId(forFlatPosition: index)
                    // Suppress error emission for 2 s — the in-place switch
                    // can transiently error during screen recording or a brief
                    // codec re-init, but AVPlayer recovers on its own.
                    self.audioSwitchSuppressUntil = Date().addingTimeInterval(2.0)
                    SBMLog.log(
                        "selectAudioTrack: flat=\(index) -> id=\(trackId) "
                        + "smb=\(self.isSMBStream) "
                        + "now=\(self.engine?.currentTime ?? .zero)s "
                        + "tracks=\(self.engine?.audioTracks.count ?? 0)")
                    // Capture the position BEFORE attempting the in-place
                    // switch. On a network source that attempt is what resets
                    // the playhead (the engine must re-probe the container and
                    // its loopback/ByteRange reader cannot rewind), so reading
                    // currentTime afterwards always yields 0 and the reload
                    // below faithfully restarts the file from the beginning.
                    // A resumed network session reports a live playhead of ~0
                    // until `reassertPosition` lands it, so a reload aimed at the
                    // playhead would discard the resume. Prefer the position the
                    // session is still trying to reach — but only while the
                    // playhead is still at the start, so a stale target can never
                    // yank the viewer back once playback has moved on.
                    let livePosition = self.engine?.currentTime ?? .zero
                    let resumeAt: Double
                    if self.pendingResumeSeconds > 0, livePosition <= 0.5 {
                        resumeAt = self.pendingResumeSeconds
                    } else {
                        resumeAt = livePosition
                    }
                    // SMB skips the in-place attempt entirely. The engine
                    // cannot switch tracks on a custom ByteRangeSource: it
                    // re-probes the container against the reader that is
                    // already streaming, which cannot rewind. That internal
                    // reload fails ("Demuxer: open failed (Operation not
                    // permitted (-1))") and latches .error before our own
                    // recovery reload ever runs. For HTTP/FTP the attempt is
                    // harmless, so it is left in place for them.
                    // Two cases need no reload on SMB:
                    //  * Dart auto-restores the saved audio track ~500 ms after
                    //    open, at position 0, while the initial load is still
                    //    settling — reloading there is pure cost and raced the
                    //    load it was meant to fix.
                    //  * A genuine mid-playback switch still needs a fresh
                    //    reader, because the in-place attempt cannot rewind.
                    // At the very start of a session there is nothing to
                    // rewind: the reader is already positioned at 0, so the
                    // in-place switch is both safe and free.
                    let atSessionStart: Bool
                    if case .loading = self.engine?.state {
                        atSessionStart = true
                    } else {
                        atSessionStart = resumeAt <= 0.5
                    }
                    let skipInPlace = self.isSMBStream && !atSessionStart
                    if atSessionStart && self.isSMBStream {
                        SBMLog.log(
                            "selectAudioTrack: SMB — at session start, "
                            + "taking the track in place")
                        self.engine?.selectAudioTrack(index: trackId)
                    } else if skipInPlace {
                        SBMLog.log(
                            "selectAudioTrack: SMB — skipping the in-place "
                            + "attempt, reloading directly at \(resumeAt)s")
                    } else {
                        SBMLog.log("selectAudioTrack: in-place attempt at \(resumeAt)s")
                        self.engine?.selectAudioTrack(index: trackId)
                    }
                    // Network / custom-IO sources (WebDAV, FTP/SFTP, Jellyfin
                    // direct-play over HTTP) cannot switch the audio track in
                    // place: the engine must re-probe the container, but its
                    // loopback/ByteRange reader can't rewind without a fresh
                    // source.  The engine does not always surface this as an
                    // error (it can silently no-op the switch), so proactively
                    // reload the session from the position we captured above and
                    // re-apply the chosen track to guarantee the selection takes
                    // effect. Local files are left alone — AVPlayer handles
                    // in-place track selection natively without a reload, which
                    // avoids conflicting with ReplayKit during screen recording.
                    let scheme = self.currentSourceURL?.scheme?.lowercased()
                    let isNetworkSource = scheme == "http" || scheme == "https"
                        || scheme == "ftp" || scheme == "sftp"
                        || scheme == "dreamplayersmb"
                        || self.lastWebDAVInfo != nil || self.lastFtpUri != nil
                        || self.isSMBStream
                    if isNetworkSource {
                        Task { @MainActor [weak self] in
                            guard let self, self.engine != nil else { return }
                            // Hold playback across a SESSION-START restore.
                            //
                            // A custom source cannot switch tracks in place — the
                            // engine must re-probe — so the saved track can only
                            // be applied after a reload, and a reloaded session
                            // autoplays the container's default track. The viewer
                            // heard that default (Hindi) for the ~300ms before
                            // the saved one (Marathi) landed.
                            //
                            // Keyed on `atSessionStart` ALONE. An earlier attempt
                            // also required `engine.state == .playing`, which can
                            // never be true here: the engine is in `.loading` at
                            // this point, and that is exactly what makes
                            // `atSessionStart` true. The condition was therefore
                            // always false and the hold never ran.
                            //
                            // Mid-playback switches are untouched: they reload at
                            // the current position, so there is no gap to hide.
                            let heldForRestore = atSessionStart
                            if heldForRestore {
                                SBMLog.log(
                                    "selectAudioTrack: holding playback across the "
                                    + "session-start restore")
                            }
                            defer {
                                if heldForRestore {
                                    self.engine?.play()
                                    SBMLog.log(
                                        "selectAudioTrack: released after the "
                                        + "session-start restore")
                                }
                            }
                            // Let the engine settle its in-place attempt first.
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            // autoplay: false so the reloaded session is paused
                            // the instant it exists; the defer above starts it once
                            // the saved track has been applied.
                            await self.reloadSession(
                                at: resumeAt, autoplay: !heldForRestore)
                            // Wait for the freshly loaded engine to reach
                            // .ready so selectAudioTrack is honored.
                            await self.waitForEngineReady(timeout: 3.0)
                            // Belt and braces: the pause issued the instant the
                            // session was created can be dropped if the engine was
                            // still loading. Now that it is ready it will stick, so
                            // the default track is silent right up to the switch.
                            if heldForRestore, self.engine?.state == .playing {
                                self.engine?.pause()
                                SBMLog.log(
                                    "selectAudioTrack: re-held once the engine "
                                    + "was ready")
                            }
                            let trackId2 = self.engineAudioId(forFlatPosition: index)
                            if skipInPlace {
                                // First selection of this track: there was no
                                // in-place attempt, so this one is applied on
                                // the freshly loaded source.
                                SBMLog.log("selectAudioTrack: applying on the reloaded source")
                            }
                            self.engine?.selectAudioTrack(index: trackId2)
                            // Re-applying the selection makes the engine
                            // re-probe the container, which drops the playhead
                            // a second time — put it back where it was.
                            await self.reassertPosition(resumeAt, attempts: 3)
                            SBMLog.log("selectAudioTrack: reloaded + re-asserted")
                            self.emit()
                        }
                    }
                    result(nil)
                case "setSubtitles":
                    let on = (args?["on"] as? Bool) ?? true
                    self.setSubtitles(on)
                    result(nil)
                case "getSubtitleTracks":
                    result(self.subtitleTrackMaps())
                case "setSubtitleTrack":
                    let index = (args?["index"] as? NSNumber)?.intValue ?? -1
                    self.selectSubtitleTrack(index)
                    result(nil)
                case "setSubtitleStyle":
                    let size = (args?["size"] as? NSNumber)?.doubleValue ?? 1.0
                    let color = (args?["color"] as? NSNumber)?.intValue ?? 0xFFFFFFFF
                    let bg = (args?["bg"] as? NSNumber)?.intValue ?? 0x80000000
                    let outline = (args?["outline"] as? Bool) ?? true
                    let vPos = (args?["vPos"] as? NSNumber)?.intValue ?? 20
                    self.subtitleDelaySeconds =
                        ((args?["delayMs"] as? NSNumber)?.doubleValue ?? 0) / 1000.0
                    self.subtitleOverlay.applyStyle(
                        size: size, color: color, bg: bg, outline: outline, verticalPosition: vPos)
                    result(nil)
                case "setResizeMode":
                    let mode = (args?["mode"] as? NSNumber)?.intValue ?? 0
                    self.setResizeMode(mode)
                    result(nil)
                case "setSpeed":
                    let speed = Float((args?["speed"] as? NSNumber)?.doubleValue ?? 1.0)
                    self.applySpeed(min(max(speed, 0.25), 4.0))
                    result(nil)
                case "enterPip":
                    self.ensurePipController()
                    self.pipController?.startPictureInPicture()
                    result(nil)
                case "setBrightness":
                    let brightness = (args?["brightness"] as? NSNumber)?.floatValue ?? 0.5
                    UIScreen.main.brightness = CGFloat(max(0, min(brightness, 1)))
                    result(nil)
                case "getBrightness":
                    result(Float(UIScreen.main.brightness))
                case "getSystemVolume":
                    let vol = AVAudioSession.sharedInstance().outputVolume
                    result(Float(vol))
                case "setSystemVolume":
                    let volume = min(max(((args?["volume"] as? NSNumber)?.floatValue ?? 1), 0), 1)
                    self.setSystemVolume(volume)
                    result(nil)
                case "setAudioBoost":
                    let boost = Float((args?["boost"] as? NSNumber)?.doubleValue ?? 1.0)
                    self.audioBoost = min(max(boost, 1), 3)
                    UserDefaults.standard.set(Double(self.audioBoost), forKey: "flutter.dreamplayer.audioBoost")
                    self.applyAudioBoost()
                    result(nil)
                case "setNightMode":
                    let enabled = (args?["enabled"] as? Bool) ?? false
                    self.nightModeEnabled = enabled
                    UserDefaults.standard.set(enabled, forKey: "flutter.dreamplayer.nightMode")
                    self.applyAudioBoost()
                    result(nil)
                case "setZoom":
                    let scale = CGFloat((args?["scale"] as? NSNumber)?.doubleValue ?? 1.0)
                    self.setZoom(min(max(scale, 1.0), 3.0))
                    result(nil)
                case "dispose":
                    self.teardownAll()
                    result(nil)
                default:
                    result(FlutterMethodNotImplemented)
                }
            }
        }
    }

    // MARK: - FlutterPlatformView

    func view() -> UIView { container }

    func dispose() {
        teardownAll()
    }

    // MARK: - FlutterStreamHandler

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        startTickTimer()
        emit()
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        stopTickTimer()
        return nil
    }

    // MARK: - Engine observation

    private func observeEngine(_ engine: AetherEngine) {
        engine.$state.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.emit() }
        }.store(in: &cancellables)
        engine.$isBuffering.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.emit() }
        }.store(in: &cancellables)
        engine.$duration.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.emit() }
        }.store(in: &cancellables)
        engine.$audioTracks.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.emit() }
        }.store(in: &cancellables)
        engine.$subtitleTracks.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.emit() }
        }.store(in: &cancellables)
        engine.$activeAudioTrackIndex.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.emit() }
        }.store(in: &cancellables)
        engine.$activeSubtitleTrackIndex.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.emit() }
        }.store(in: &cancellables)
        engine.$videoFormat.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.emit() }
        }.store(in: &cancellables)

        engine.clock.$sourceTime.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateSubtitleOverlay() }
        }.store(in: &cancellables)
        engine.$subtitleCues.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateSubtitleOverlay() }
        }.store(in: &cancellables)
    }

    // MARK: - Playback

    private func open(_ args: [String: Any]?, _ result: FlutterResult) {
        guard let engine else {
            result(FlutterError(code: "engine_init", message: "AetherEngine failed to initialize", details: nil))
            return
        }
         // New file is being opened — clear the background-reload flag so we
         // don't immediately reload a freshly-opened source.
         needsReloadAfterBackground = false
         let path = args?["path"] as? String
         let uri = args?["uri"] as? String
         let subtitleUri = args?["subtitleUri"] as? String
         // Carries the saved SMB server id ("smb:<id>/<share>/<path>"), which
         // is how a raw smb:// URI is matched back to its credentials.
         let resumeKey = args?["resumeKey"] as? String
         // Identity of the source being opened — used to detect
         // same-file re-opens (resume/replay) where the engine probe
         // may drop DV info when loading with a start position.
         let newKey = (path ?? uri ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Lock-screen title (same payload Android reads natively).
        if let t = args?["title"] as? String, !t.isEmpty { mediaTitle = t }
        let startMs = (args?["startPositionMs"] as? NSNumber)?.int64Value ?? 0
        // HTTP request headers (e.g. WebDAV Basic auth) + per-server self-signed
        // opt-in, both per media item at open time (same contract as Android).
        let httpHeaders = (args?["headers"] as? [String: String]) ?? [:]
        let allowSelfSigned = (args?["allowSelfSigned"] as? Bool) ?? false

        // Source pending construction: some sources need background I/O
        var source: MediaSource?
        var localURL: URL?
        var webDAVSource: (url: URL, headers: [String: String], allowSelfSigned: Bool)?
        var ftpUri: String?
        smbToken = nil
        isSMBStream = false
        smbFormatHint = nil
        smbUri = nil
        smbServerId = nil
        smbPlayback = nil
        let smbResume = Self.smbParts(fromResumeKey: resumeKey)
        if let uri, uri.hasPrefix("dreamplayersmb://"),
           let connection = SMBBridge.shared.session(for: uri) {
            // Must precede the plain-path branch: Dart sends `path` alongside
            // `uri`, and an SMB item's path is "smb://share/file", which as a
            // file:// URL is ENOENT.
            // SMBBridge.openShare minted this token and is holding the live
            // session. One open handle answers every read, so there is no
            // buffering layer to stall teardown on.
            smbToken = uri
            smbPlayback = connection
            isSMBStream = true
            SBMLog.log("open: SMB session for playback (\(connection.byteSize) bytes)")
            // Hold the socket: the browsing screen calls closeShare when it is
            // disposed, and that must not stop playback.
            SMBBridge.shared.setPlayerActive(true, serverId: SMBBridge.shared.serverId(forToken: uri))
            let ext = Self.smbTokenExtension(uri)
            smbFormatHint = ext.isEmpty ? Self.sniffFormatFromSMB(connection.libsmb2File) : ext
            source = .custom(connection.makeReader(), formatHint: smbFormatHint)

        } else if smbResume != nil
                    || uri?.lowercased().hasPrefix("smb://") == true
                    || uri?.hasPrefix("dreamplayersmb://") == true {
            // A bookmarked folder card or Continue-Watching entry hands the
            // player its stored smb:// URI rather than a token, and the engine
            // has no smb scheme. Resolving it means a blocking SMB handshake,
            // so it is built inside the load Task like the FTP/WebDAV paths —
            // doing it here froze the main thread on a spinner.
            //
            // The condition above tests `uri` with optional chaining, so it does
            // not bind it: unwrap here. A resumed item may also carry no `uri`
            // at all (path only), in which case the durable resume key is the
            // only handle — synthesise an smb:// URI from it so the load Task
            // has something to work from.
            if let stored = uri {
                smbUri = stored
            } else if let parts = smbResume {
                smbUri = "smb://\(parts.id)/\(parts.share)/\(parts.path)"
            }
            smbServerId = smbResume?.id
            if let resolved = smbUri {
                localURL = URL(string: resolved)
            }
            source = nil
        } else if let path, !path.isEmpty {
            localURL = URL(fileURLWithPath: path)
            source = .url(localURL!)
        } else if let uri, uri.lowercased().hasPrefix("ftp://") || uri.lowercased().hasPrefix("sftp://") {
            // FTP/SFTP playback: the engine has no FTP stack, so serve it via
            // FtpClient's ByteRangeSource (plain-FTP REST reads or Citadel
            // SFTP offset reads) wrapped in BufferedSMBReader read-ahead —
            // the same shape as the WebDAV path below. Built inside the load
            // Task so the blocking handshake never touches the main thread.
            ftpUri = uri
            localURL = URL(string: uri)
            source = nil
        } else if let uri, let u = URL(string: uri),
                  (u.scheme?.lowercased() == "http" || u.scheme?.lowercased() == "https"),
                  !httpHeaders.isEmpty || allowSelfSigned {
            // WebDAV playback: auth headers AND self-signed HTTPS can't go
            // through AetherEngine's own HTTP stack (no headers API, and its
            // TLS validation can't be bypassed), so serve the stream as a
            // custom ByteRangeSource — each read is an independent HTTP Range
            // request carrying the Authorization header on the permissive or
            // default-trust session. Wrapped in BufferedSMBReader for read-ahead (the
            // loopback producer starves on per-read network round-trips). The
            // source is stateless per read, so the engine's internal reload on
            // audio-track switch is safe.
            localURL = u
            webDAVSource = (u, httpHeaders, allowSelfSigned)
        } else if let uri, let u = URL(string: uri) {
            localURL = u
            source = .url(u)
        } else {
            result(FlutterError(code: "bad_args", message: "Missing path or uri", details: nil))
            return
        }

        // Play audio even with the mute switch on.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        UIApplication.shared.isIdleTimerDisabled = true

         // Reset per-open state.
         // Probe/HDR state survives a re-open of the SAME file (resume/replay):
         // the engine probe can drop DV info when loading with a start position,
         // which would regress the badge to SDR. Only cleared when a different
         // file is opened.
         lastError = nil
         pendingAutoSubtitleIndex = nil
         let sameFile = !newKey.isEmpty && newKey == Self.lastOpenedKey
         Self.lastOpenedKey = newKey
         if !sameFile {
             videoCodecName = nil
             videoWidth = 0
             videoHeight = 0
             isDolbyVision = false
             dvProfile = nil
             dvUnsupportedProfile = nil
             isHdr10PlusContent = false
             isHdr10Content = false
         } else {
         }
         lastWebDAVInfo = nil
         lastFtpUri = nil
         chapters = []
         subtitleOverlay.clear()
         invalidatePipController()
         emit()

        // Sidecar subtitles: an explicit `subtitleUri` wins; then external
        // subtitles from the server (e.g. Jellyfin); then auto-pair sibling
        // files in the video's folder (best match first, like Android).
        var externals: [ExternalSubtitleTrack] = []
        if let subtitleUri, !subtitleUri.isEmpty, let sub = Self.url(for: subtitleUri) {
            externals.append(ExternalSubtitleTrack(url: sub, isDefault: true, formatHint: sub.pathExtension.lowercased()))
            pendingAutoSubtitleIndex = AetherEngine.externalSubtitleTrackIDBase + 0
        } else if let localURL, localURL.isFileURL {
            externals = Self.siblingSubtitles(for: localURL)
            if let best = externals.firstIndex(where: { $0.isDefault }) {
                pendingAutoSubtitleIndex = AetherEngine.externalSubtitleTrackIDBase + best
            }
        }
        // External subtitles from the server (e.g. Jellyfin DeliveryUrl).
        if let rawExternalSubs = args?["externalSubtitles"] as? [[String: Any]] {
            for entry in rawExternalSubs {
                guard let urlStr = entry["uri"] as? String,
                      !urlStr.isEmpty,
                      let url = URL(string: urlStr) else { continue }
                let label = entry["label"] as? String ?? "Track"
                let language = entry["language"] as? String ?? ""
                let isDefault = entry["isDefault"] as? Bool == true
                let mimeType = entry["mimeType"] as? String ?? "application/x-subrip"
                let formatHint = mimeType.contains("ssa") ? "ass"
                    : mimeType.contains("vtt") ? "vtt"
                    : mimeType.contains("ttml") ? "ttml"
                    : "srt"
                let track = ExternalSubtitleTrack(
                    url: url,
                    name: language.isEmpty ? label : "\(language) · \(label)",
                    language: language.isEmpty ? nil : language,
                    isForced: false,
                    isHearingImpaired: false,
                    isDefault: isDefault,
                    formatHint: formatHint,
                )
                externals.append(track)
                if isDefault && pendingAutoSubtitleIndex == nil {
                    pendingAutoSubtitleIndex = AetherEngine.externalSubtitleTrackIDBase + (externals.count - 1)
                }
            }
        }

        let options = LoadOptions(
            httpHeaders: [:],
            panelIsInHDRMode: UIScreen.main.currentEDRHeadroom > 1.0,
            preferredAudioLanguages: [],
            preferredSubtitleLanguages: [],
            externalSubtitles: externals,
            autoplay: true
        )
        lastSource = source
        lastLoadOptions = options
        // Resume: continue from the last watched position when the caller asks.
        let startPosition: Double? = startMs > 0 ? Double(startMs) / 1000.0 : nil

        // Armed here, BEFORE the load, and not after it. `engine.load` does not
        // return until the container is probed, and Dart's audio-track restore
        // arrives ~75 ms into that window — before the post-load code ran, so
        // the pending target was still 0 and the restore's reload pinned the
        // session to the start. Arming late made the fix a no-op on exactly the
        // case it was written for: a resume that also has a saved non-default
        // audio track, which is the only case that reloads at session start.
        pendingResumeSeconds = startPosition ?? 0
        if pendingResumeSeconds > 0 {
            SBMLog.log("open: resume target armed at \(pendingResumeSeconds)s "
                       + "(before load, so a session-start reload cannot discard it)")
        }

        Task { @MainActor [weak self] in
            guard let self, let engine = self.engine else { return }
            do {
                if let pendingSmbUri = smbUri {
                    // Blocking handshake (login + tree connect + stat) — keep it
                    // off the main actor or the UI locks on a spinner. The
                    // server id is read here, on the actor, because touching
                    // main-actor state from inside the detached closure is an
                    // isolation violation.
                    // A live token is the cheap path; otherwise rebuild from
                    // the resume key, which survives a restart. Falling through
                    // to the plain-path branch here is what turned a stale
                    // token into "No such file or directory".
                    let serverId = smbServerId
                    let parts = smbResume
                    let connection: SMBPlayback? =
                        await Task.detached(priority: .userInitiated) {
                            if let live = SMBBridge.shared.session(
                                for: pendingSmbUri
                            ) {
                                return live
                            }
                            if let parts {
                                SBMLog.log(
                                    "open: token is stale, re-opening from "
                                    + "resumeKey server=\(parts.id) "
                                    + "share=\(parts.share)")
                                return SMBBridge.shared.openSmb(
                                    serverId: parts.id,
                                    share: parts.share,
                                    path: parts.path
                                )
                            }
                            return SMBBridge.shared.openFromSmbUri(
                                pendingSmbUri, serverId: serverId
                            )
                        }.value
                    if let connection {
                        self.smbPlayback = connection
                        self.isSMBStream = true
                        let ext = (pendingSmbUri as NSString).pathExtension
                        self.smbFormatHint = ext.isEmpty
                            ? Self.sniffFormatFromSMB(connection.libsmb2File)
                            : ext
                        source = .custom(
                            connection.makeReader(),
                            formatHint: self.smbFormatHint
                        )
                    } else {
                        self.lastError = "Could not open that file on the SMB share"
                        self.emit()
                        return
                    }
                }
                if let pendingFtpUri = ftpUri {
                    // Handshake (login + PASV/SFTP open) is blocking I/O —
                    // keep it off the main actor like the WebDAV probe.
                    let buffered = try await Task.detached(priority: .userInitiated) {
                        try await FtpClient.makeByteRangeSource(uriText: pendingFtpUri)
                    }.value
                    let ext = URL(string: pendingFtpUri)?.pathExtension.lowercased() ?? ""
                    source = .custom(
                        buffered,
                        formatHint: ext.isEmpty ? nil : ext
                    )
                }
                if let (webURL, webHeaders, webAllowSelfSigned) = webDAVSource {
                    // Size probe is a blocking URLSession round-trip; keep it
                    // off the main actor.
                    let byteSource = try await Task.detached(priority: .userInitiated) {
                        try WebDAVClient.shared.makeByteRangeSource(
                            url: webURL,
                            headers: webHeaders,
                            allowSelfSigned: webAllowSelfSigned
                        )
                    }.value
                    let ext = webURL.pathExtension.lowercased()
                    source = .custom(
                        BufferedSMBReader(source: byteSource),
                        formatHint: ext.isEmpty ? nil : ext
                    )
                }
                guard let finalSource = source else {
                    SBMLog.log("open: NO SOURCE. path=\(path ?? "nil") uri=\(uri ?? "nil")")
                    self.lastError = "Missing media source"
                    self.emit()
                    return
                }
                SBMLog.log(
                    "open: source=\(self.isSMBStream ? "smb-custom" : "other") "
                    + "hint=\(self.smbFormatHint ?? "none") path=\(path ?? "nil") uri=\(uri ?? "nil")")
                self.lastSource = finalSource
                self.lastWebDAVInfo = webDAVSource
                self.lastFtpUri = ftpUri
                // Capture source scheme + final URL for the network chip.
                // localURL is the original URL we resolved at the top of open()
                // (file:// for paths, http(s):// for URIs, etc.).
                self.currentSourceURL = localURL
                let scheme: String
                if let lu = localURL {
                    if ftpUri != nil { scheme = "ftp" } // sftp:// too
                    else { scheme = lu.scheme?.lowercased() ?? "" }
                } else {
                    scheme = ""
                }
                self.currentSourceScheme = scheme
                 let probe = try await engine.load(source: finalSource, startPosition: startPosition, options: options)
                 if let probe {
                     // The probe can drop DV info when loading with a start
                     // position (resume/replay). Keep the earlier detection
                     // instead of regressing the badge to SDR.
                     self.videoCodecName = probe.videoCodecName ?? self.videoCodecName
                     self.videoWidth = probe.videoWidth > 0 ? Int(probe.videoWidth) : self.videoWidth
                     self.videoHeight = probe.videoHeight > 0 ? Int(probe.videoHeight) : self.videoHeight
                     self.isDolbyVision = probe.isDolbyVision || self.isDolbyVision
                     self.dvProfile = probe.dvProfile ?? self.dvProfile
                 }
                // Dolby Vision Profile 4 cannot be decoded on iOS — reject it
                // here, while we still know what the file is, so the user gets
                // "Profile 4 is a broadcast format iOS does not decode" instead
                // of the engine's opaque "playback failed" some seconds later.
                if Self.isUnsupportedDVProfile(dvProfile, isDV: isDolbyVision) {
                    dvUnsupportedProfile = "UnsupportedDolbyVisionProfile4"
                    engine.pause()
                    lastError = dvUnsupportedProfile
                    self.emit()
                    // Return from this Task only — the shared `result(nil)`
                    // after the Task closes the Dart `open()` future. Do NOT
                    // call `result` here: it is a non-escaping parameter, and
                    // the Task would both fail to compile and double-send.
                    return
                }
                if let pending = self.pendingAutoSubtitleIndex,
                   engine.subtitleTracks.contains(where: { $0.id == pending }) {
                    engine.selectSubtitleTrack(index: pending)
                }
                self.pendingAutoSubtitleIndex = nil
                // Fresh AVPlayer instance after load — re-apply the saved rate.
                self.applySpeed(self.pendingSpeed)
                // Fresh player layer too — (re)arm picture-in-picture.
                self.ensurePipController()
                // Reset any pinch-zoom from a previous session.
                self.setZoom(1.0)
                // Resume is not reliable from the load parameter alone on every
                // source type: the network path (Jellyfin direct-play, plain
                // http(s)) goes through AetherEngine's own loopback producer
                // rather than a local AVPlayer item, and there the start
                // position is not always honoured — the session comes up at 0.
                // Re-assert it once the engine is actually ready so a tap on a
                // Continue watching card lands where the viewer left off.
                if let startPosition, startPosition > 0 {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.reassertPosition(startPosition)
                        self.emit()
                    }
                }
                self.emit()
                // Probe chapters for local / Files-app SMB files. The provider
                // mounts SMB at a local path, so a FileHandle read suffices
                // (HTTP/WebDAV MKVs don't need this — they have no browsable
                // container on iOS either way). MKV via `MkvChapters`; MP4/MOV
                // (`moov/udta/chpl` Nero) via the raw box scan (`Mp4Chapters`).
                if let fileURL = localURL, fileURL.isFileURL {
                    let ext = fileURL.pathExtension.lowercased()
                    if ["mkv", "mka", "mks", "webm", "mk3d"].contains(ext) {
                        let path = fileURL.path
                        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                            let maps = MkvChapters.parseMaps(path: path)
                            if maps.isEmpty { return }
                            DispatchQueue.main.async { [weak self] in
                                guard let self else { return }
                                self.chapters = maps
                                self.emit()
                            }
                        }
                    }
                    if ["mp4", "mov", "m4v", "m4b", "3gp"].contains(ext) {
                        let path = fileURL.path
                        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                            // Nero `chpl` box scan (Mp4Chapters) — the same
                            // parser as Android (`Mp4Chapters.kt`). HandBrake /
                            // FFmpeg write chpl; AVFoundation's chapter API has
                            // no stable async property key, so the raw parser
                            // is used directly.
                            let maps = Mp4Chapters.parseMaps(path: path)
                            if maps.isEmpty { return }
                            DispatchQueue.main.async { [weak self] in
                                guard let self else { return }
                                self.chapters = maps
                                self.emit()
                            }
                        }
                    }
                    // Bitstream HDR probes (best-effort, like Android).
                    // Engine may already report .hdr10Plus, but plain HDR10 MKVs
                    // that omit the Matroska Colour element report .sdr — the
                    // SEI 137/144 scan upgrades them to HDR10. Scan the first
                    // ~8 MiB for HEVC SEI NALs (prefix 39 / suffix 40, ITU-T T.35
                    // B5 00 3C for HDR10+, 137/144 for static HDR10).
                    // Only run the byte-scan on HEVC-family codecs — an H.264
                    // SDR file must never badge HDR10 via a random SEI alias
                    // (the old noteCodec heuristic counted 0x40/0x42 as HEVC).
                    let codecForHdr = (probe?.videoCodecName ?? "").lowercased()
                    let hevcFamily = codecForHdr.contains("hevc")
                        || codecForHdr.contains("hev1")
                        || codecForHdr.contains("hvc1")
                        || codecForHdr.hasPrefix("dv")
                    if hevcFamily {
                        let hdrPath = fileURL.path
                        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                            let res = Self.scanHdrProbe(path: hdrPath)
                            if res.hdr10Plus || res.hdr10 {
                                DispatchQueue.main.async { [weak self] in
                                    guard let self else { return }
                                    if res.hdr10Plus, !self.isHdr10PlusContent {
                                        self.isHdr10PlusContent = true
                                    }
                                    if res.hdr10, !self.isHdr10Content {
                                        self.isHdr10Content = true
                                    }
                                    self.emit()
                                }
                            }
                        }
                    }
                }
            } catch let error as CancellationError {
                // Load superseded by a newer open/reload — not a playback failure.
            } catch {
                self.lastError = String(describing: error)
                self.emit()
            }
        }
        result(nil)
    }

    /// Replays the last-opened source at `position` seconds. AetherEngine treats
    /// `.ended` as terminal (seek/play are no-ops there), so a replay / scrubber
    /// pull-back after the end card reloads the session instead.
    /// For WebDAV custom sources the underlying IOReader is consumed and
    /// can't rewind, so we re-resolve a fresh source instead of reusing `lastSource`.
    private var reloadInFlight = false

    /// Where this session is still trying to land, in seconds.
    ///
    /// `engine.load(startPosition:)` is ignored for network sources, so a resume
    /// is applied asynchronously by `reassertPosition` — which sleeps ~900 ms
    /// before its first attempt. Anything that reloads the session in that
    /// window used to read the live playhead, still ~0, and so reload the whole
    /// session at 0. Dart's audio-track restore fires at ~85 ms, which is
    /// exactly that window: the reload pinned the session to the start and the
    /// trailing `reassertPosition(0)` then returned immediately on its
    /// `position > 2` guard, so the resume was lost outright.
    ///
    /// Cleared as soon as the engine is actually seen at (or past) the target,
    /// so a later deliberate seek is never rewound by this.
    private var pendingResumeSeconds: Double = 0

    /// - Parameter autoplay: when false the freshly loaded session is paused
    ///   immediately, before any `await`, and the caller is responsible for
    ///   starting it. Used by the session-start audio-track restore, where the
    ///   container's default track would otherwise be audible between the
    ///   reload completing and the saved track being applied.
    private func reloadSession(at position: Double, autoplay: Bool = true) async {
        // The Dart replay button sends seekTo(0) AND play() back-to-back; each
        // triggers a reload here. A second engine.load supersedes the first,
        // which then throws CancellationError — so coalesce duplicates and let
        // one reload run at a time.
        guard !reloadInFlight else { return }
        reloadInFlight = true
        defer { reloadInFlight = false }
        guard let engine else { return }
        let activeSub = engine.activeSubtitleTrackIndex
        SBMLog.log("reloadSession: start at \(position)s (smb=\(isSMBStream))")
        do {
            let freshSource = try await buildFreshSource()
            guard let freshSource else {
                SBMLog.log("reloadSession: buildFreshSource returned nil — aborting")
                return
            }
            lastSource = freshSource
             let probe = try await engine.load(source: freshSource, startPosition: position, options: lastLoadOptions)
             if !autoplay {
                 // Synchronous, immediately after the session exists and before
                 // any suspension point, so the default track is audible for
                 // milliseconds rather than the ~300ms this used to take.
                 engine.pause()
                 SBMLog.log("reloadSession: paused on load (autoplay: false)")
             }
             if let probe {
                 // Same-file reload can drop DV info (startPosition load).
                 // Keep the earlier detection instead of regressing to SDR.
                 videoCodecName = probe.videoCodecName ?? self.videoCodecName
                 videoWidth = probe.videoWidth > 0 ? Int(probe.videoWidth) : self.videoWidth
                 videoHeight = probe.videoHeight > 0 ? Int(probe.videoHeight) : self.videoHeight
                 isDolbyVision = probe.isDolbyVision || self.isDolbyVision
                 dvProfile = probe.dvProfile ?? self.dvProfile
             }
            if let activeSub, engine.subtitleTracks.contains(where: { $0.id == activeSub }) {
                engine.selectSubtitleTrack(index: activeSub)
            }
            // Fresh AVPlayer instance after reload — re-apply the saved rate.
            applySpeed(pendingSpeed)
            // `load(startPosition:)` is not honoured for network sources, so a
            // reload from a saved position still comes up at 0. Re-assert it.
            await reassertPosition(position)
            SBMLog.log("reloadSession: done at \(position)s")
        } catch let error as CancellationError {
            // Superseded by a newer load elsewhere — not a playback failure.
            SBMLog.log("reloadSession: cancelled (superseded)")
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Waits until the engine reaches a state that accepts track-switch
    /// commands (`.playing`/`.paused`/`.ended`, or `.error` to bail) with a
    /// timeout.  The engine's `PlaybackState` doesn't expose a `.ready`
    /// case — once `engine.load(...)` finishes probing, it transitions to
    /// `.playing` (or `.paused` if `autoplay` was false).  Track switches
    /// issued during `.loading`/`.seeking` are silently ignored.
    private func waitForEngineReady(timeout: TimeInterval) async {
        guard let engine = self.engine else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch engine.state {
            case .playing, .paused, .ended:
                return
            case .error:
                return
            default:
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Moves the playhead to `position` when the engine came up short of it.
    ///
    /// `engine.load(startPosition:)` is honoured for local AVPlayer items but
    /// not for network sources: Jellyfin direct-play and plain http(s) are fed
    /// to the engine through its own loopback producer, where the session
    /// always opens at 0. The same happens when an audio-track change forces
    /// the engine to re-probe the container.
    ///
    /// A seek issued the moment the engine reports ready is routinely
    /// swallowed — the loopback producer is still filling and has no data at
    /// that offset yet. A seek issued later on the same session works, which
    /// is why scrubbing by hand is reliable while resume is not. So this
    /// retries: seek, let the producer catch up, and re-issue while the
    /// playhead is still short. It stops as soon as the position sticks.
    ///
    /// Positions under ~2 s are ignored so a deliberate "start from the top"
    /// is never undone.
    private func reassertPosition(
        _ position: Double,
        attempts: Int = 5,
        settle: UInt64 = 900_000_000
    ) async {
        guard position > 2.0 else { return }
        for _ in 0..<attempts {
            guard let engine = self.engine else { return }
            await waitForEngineReady(timeout: 5.0)
            guard let engine = self.engine else { return }
            guard engine.currentTime < position * 0.9 else {
                // Landed: stop advertising a target, so a later reload uses the
                // real playhead and a deliberate seek is not undone.
                if pendingResumeSeconds > 0, pendingResumeSeconds <= position {
                    pendingResumeSeconds = 0
                }
                return
            }
            await engine.seek(to: position)
            // Let the seek land before deciding whether to try again.
            try? await Task.sleep(nanoseconds: settle)
        }
    }


    /// Converts a Dart flat position (the `index` field in the
    /// `audioTracks` map) to the engine's native audio track `id`.
    /// `engine.selectAudioTrack(index:)` expects that `id`.
    private func engineAudioId(forFlatPosition pos: Int) -> Int {
        guard let engine = self.engine, pos >= 0, pos < engine.audioTracks.count else { return pos }
        return engine.audioTracks[pos].id
    }

    /// Builds a fresh `MediaSource` from the stored open info.
    /// FTP/SFTP: new login + PASV/handle → new BufferedSMBReader.
    /// WebDAV: new HTTP session → new BufferedSMBReader.
    /// Local file: reuses the file URL (always re-openable).
    private func buildFreshSource() async throws -> MediaSource? {
        if let playback = smbPlayback {
            // A FRESH source over the SAME open handle. This is the whole point
            // of the stateless reader: the old ring buffer was one-shot, drained
            // with its cursor at EOF by the time a reload happened, so the
            // engine's container probe read nothing ("custom source probe
            // failed"). Ranged reads have no cursor to lose.
            SBMLog.log(
                "buildFreshSource: SMB — new source on the live handle "
                + "(\(playback.byteSize) bytes, hint=\(smbFormatHint ?? "none"))")
            return .custom(playback.makeReader(), formatHint: smbFormatHint)
        }
        if let ftpUri = lastFtpUri {
            let buffered = try await Task.detached(priority: .userInitiated) {
                try await FtpClient.makeByteRangeSource(uriText: ftpUri)
            }.value
            let ext = URL(string: ftpUri)?.pathExtension.lowercased() ?? ""
            return .custom(
                buffered,
                formatHint: ext.isEmpty ? nil : ext
            )
        }
        if let web = lastWebDAVInfo {
            let byteSource = try await Task.detached(priority: .userInitiated) {
                try WebDAVClient.shared.makeByteRangeSource(
                    url: web.url,
                    headers: web.headers,
                    allowSelfSigned: web.allowSelfSigned
                )
            }.value
            let ext = web.url.pathExtension.lowercased()
            return .custom(
                BufferedSMBReader(source: byteSource),
                formatHint: ext.isEmpty ? nil : ext
            )
        }
        SBMLog.log("buildFreshSource: reusing lastSource (local file)")
        return lastSource  // local file: always re-openable
    }

    // MARK: - Fit / zoom mode

    /// Maps the Dart-side [VideoFitMode] to AVPlayerLayer videoGravity. The
    /// layer lives inside AetherEngine's `AetherPlayerView`; we locate it via
    /// the view hierarchy. Fixed ratios (16:9 / 4:3) are approximated with
    /// `.resizeAspectFill` (crop) — exact fixed-ratio boxes need the engine's
    /// own layout hooks, revisit on-device on the iPad.
    private func setResizeMode(_ mode: Int) {
        guard let playerLayer = findPlayerLayer() else { return }
        let gravity: AVLayerVideoGravity
        switch mode {
        case 1, 3, 4: gravity = .resizeAspectFill // crop / fixed ratios
        case 2: gravity = .resize // stretch
        default: gravity = .resizeAspect // fit
        }
        if playerLayer.videoGravity != gravity {
            playerLayer.videoGravity = gravity
        }
    }

    private func findPlayerLayer() -> AVPlayerLayer? {
        if let layer = engineView.layer as? AVPlayerLayer { return layer }
        return engineView.layer.sublayers?.lazy.compactMap { $0 as? AVPlayerLayer }.first
    }

    /// Pinch-to-zoom crop: scales the video layer around its center. The
    /// `AVPlayerLayer` lives inside AetherEngine's `AetherPlayerView`; we scale
    /// the engine view's layer so the video zooms without disturbing the
    /// wrapper's own layout. Transient per session (reset to 1.0 on next open).
    private func setZoom(_ scale: CGFloat) {
        engineView.layer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
    }

    // MARK: - Picture-in-picture

    /// Floating-video controller over the engine's `AVPlayerLayer`. Only the
    /// native AVPlayer path supports it (local files / Apple containers) — the
    /// FFmpeg custom-source path has no AVPlayerLayer, so [ensurePipController]
    /// leaves the controller nil and "enterPip" is a harmless no-op there.
    private var pipController: AVPictureInPictureController?

    /// Mirrored into the event map so Dart hides its overlay controls while
    /// the video floats.
    private var inPip = false

    /// Settings toggle `dreamplayer.pipEnabled` (default true) — read
    /// natively so HOME still works when Dart is backgrounded.
    private static func pipSettingEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: "flutter.dreamplayer.pipEnabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "flutter.dreamplayer.pipEnabled")
    }

    private func ensurePipController() {
        guard pipController == nil,
              Self.pipSettingEnabled(),
              AVPictureInPictureController.isPictureInPictureSupported(),
              let layer = findPlayerLayer(),
              layer.player != nil else { return }
        let controller = AVPictureInPictureController(playerLayer: layer)
        guard let controller else { return }
        // Pressing HOME while playing floats the video automatically (same
        // trigger as Android's onUserLeaveHint path). The Settings toggle
        // gates this — when off, pipController stays nil.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = self
        pipController = controller
    }

    /// The engine builds a fresh player per load; drop any controller bound to
    /// the previous layer so the next open re-arms against the live one.
    private func invalidatePipController() {
        pipController = nil
        if inPip {
            inPip = false
            emit()
        }
    }


    // MARK: - Playback speed

    /// Last speed requested from Dart. Applied to the AVPlayerLayer's player
    /// (native AVPlayer path — local files, DV/HDR) via `defaultRate`, so
    /// play()/interruptions resume at the same rate; re-applied after every
    /// session load/reload since the engine builds a fresh player. The FFmpeg
    /// custom-source path (WebDAV) has no AVPlayer — the call is a no-op there.
    private var pendingSpeed: Float = 1.0

    private func applySpeed(_ speed: Float) {
        pendingSpeed = speed
        guard let player = Self.findAVPlayer(in: container) else { return }
        player.defaultRate = speed
        if engine?.state == .playing {
            player.rate = speed
        }
    }

    private static func findAVPlayer(in view: UIView) -> AVPlayer? {
        func walk(_ layer: CALayer) -> AVPlayer? {
            if let p = (layer as? AVPlayerLayer)?.player { return p }
            for sub in layer.sublayers ?? [] {
                if let p = walk(sub) { return p }
            }
            return nil
        }
        return walk(view.layer)
    }

    // MARK: - Track selection

    private func setSubtitles(_ on: Bool) {
        guard let engine else { return }
        if !on {
            engine.clearSubtitle()
        } else if let current = engine.activeSubtitleTrackIndex {
            engine.selectSubtitleTrack(index: current)
        } else if let first = engine.subtitleTracks.first {
            engine.selectSubtitleTrack(index: first.id)
        }
        emit()
    }

    private func selectSubtitleTrack(_ index: Int) {
        guard let engine else { return }
        if index >= 0, engine.subtitleTracks.contains(where: { $0.id == index }) {
            engine.selectSubtitleTrack(index: index)
        } else {
            engine.clearSubtitle()
        }
        emit()
    }

    // MARK: - Event emission

    private func startTickTimer() {
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.emit() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTickTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    /// True when the file is a Dolby Vision profile iOS has no decoder for.
    /// P4 is single-layer IPTPQc2 with no backward-compatible HDR10 base layer,
    /// so unlike P7/P8 there is nothing to fall back to.
    private static func isUnsupportedDVProfile(_ profile: Int?, isDV: Bool) -> Bool {
        guard isDV, let profile else { return false }
        return profile == 4
    }

    /// Reads the most recent indicated bitrate from AVPlayerItemAccessLog
    /// (the system's smoothed moving average — only populated for http/https
    /// sources; returns 0 for file://). Returns (currentBytesPerSec,
    /// peakBytesPerSec) computed from bits/sec divided by 8.
    private func stateMap() -> [String: Any] {
        guard let engine else { return [:] }
        let state = engine.state

        let st: Int
        // A file we deliberately refused (unsupported DV profile) must surface as
        // an error regardless of what the engine still thinks its state is.
        if let forcedError = dvUnsupportedProfile {
            st = 1
            lastError = forcedError
        } else {
            switch state {
            case .idle: st = 1
            case .loading, .seeking:
                st = 2
                // De-duplicated: emit() fires many times a second and an
                // unfiltered log was ~90% duplicate lines.
                let line = "engine state -> \(state)"
                if line != lastLoggedState {
                    lastLoggedState = line
                    SBMLog.log("\(line) at \(engine.currentTime)s")
                }
            case .playing, .paused: st = 3
            case .ended: st = 4
            case .error(let message):
                if Date() < audioSwitchSuppressUntil {
                    // Hide transient error during audio-switch window.
                    // If the engine recovers, this error is never shown.
                    st = 2
                    self.logErrorOnce("suppressed during switch: \(message)")
                } else {
                    st = 1
                    lastError = message
                    // Always logged, even when suppressed: a transient error
                    // that recovers is exactly what hid the audio-switch
                    // failure until now.
                    self.logErrorOnce("smb=\(isSMBStream): \(message)")
                }
            }
        }

        let playing = state == .playing
        let buffering = engine.isBuffering || state == .loading || state == .seeking
        let ended = state == .ended

        let positionMs = Int64(engine.currentTime * 1000)
        let durationMs = Int64(engine.duration * 1000)

        // Buffered position: furthest loaded time across AVPlayer's ranges.
        let bufferedMs: Int64 = {
            guard let player = findPlayerLayer()?.player,
                  let ranges = player.currentItem?.loadedTimeRanges,
                  let last = ranges.last?.timeRangeValue,
                  last.end.isValid else { return 0 }
            return Int64(CMTimeGetSeconds(last.end) * 1000)
        }()

        let engineVideoFormat = engine.videoFormat
        // DV: the engine's own .dolbyVision report is authoritative — the load
        // probe can be nil on resume/reload, which used to regress the badge
        // to SDR. (.hdr10/.hdr10Plus are NOT DV — including them here would
        // mislabel plain HDR10 files as Dolby Vision via the dvhe codec.)
        let isDVFromEngine = engineVideoFormat == .dolbyVision
        let effectiveIsDV = isDolbyVision || isDVFromEngine
        // Fallback dimensions from the played item — `presentationSize` is a
        // synchronous non-blocking AVPlayerItem property; asset.tracks() can
        // block on network sources and must not run on the platform main
        // thread. Memoized back into videoWidth/videoHeight so the subtitle
        // overlay also gets real dimensions after a probe-less resume.
        let itemSize = findPlayerLayer()?.player?.currentItem?.presentationSize ?? .zero
        let effectiveWidth = videoWidth > 0 ? videoWidth : (itemSize.width > 0 ? Int(itemSize.width) : 0)
        let effectiveHeight = videoHeight > 0 ? videoHeight : (itemSize.height > 0 ? Int(itemSize.height) : 0)
        if videoWidth == 0 && effectiveWidth > 0 { videoWidth = effectiveWidth }
        if videoHeight == 0 && effectiveHeight > 0 { videoHeight = effectiveHeight }
        let videoCodec = Self.displayVideoCodec(base: videoCodecName, isDV: effectiveIsDV, profile: dvProfile)
        let hevcForHdr: Bool = {
            let c = (videoCodecName ?? "").lowercased()
            return c.contains("hevc") || c.contains("hev1") || c.contains("hvc1") || c.hasPrefix("dv") || isDVFromEngine
        }()
        // engineVideoFormat is always available from the engine even when the
        // load probe returns nil; the mapping itself returns nil for .sdr so
        // an SDR H.264 file never badges HDR10.
        let effectiveColorTransfer = hevcForHdr ? Self.colorTransfer(for: engineVideoFormat) : nil
        let hdrPlus = isHdr10PlusContent || (hevcForHdr && engineVideoFormat == .hdr10Plus)
        let hdr10 = isHdr10Content || (hevcForHdr && (engineVideoFormat == .hdr10 || engineVideoFormat == .hdr10Plus))

        let audioTracks = audioTrackMaps()
        let activeAudio = engine.audioTracks.first(where: { $0.id == engine.activeAudioTrackIndex })
        // Flat position of the active track, matching Android's convention.
        let selectedAudio: Int = {
            guard let active = engine.activeAudioTrackIndex else { return -1 }
            return engine.audioTracks.firstIndex(where: { $0.id == active }) ?? -1
        }()

        let subtitleTracks = subtitleTrackMaps()
        let selectedSubtitle = engine.activeSubtitleTrackIndex ?? -1
        let activeSub = engine.subtitleTracks.first(where: { $0.id == engine.activeSubtitleTrackIndex })
        let subtitleOn = engine.isSubtitleActive || selectedSubtitle >= 0
        let subtitleFormat = activeSub.map { Self.subtitleFormatLabel($0.codec) } ?? ""

        let map: [String: Any] = [
            "state": st,
            "playing": playing,
            "buffering": buffering,
            "ended": ended,
            "positionMs": positionMs,
            "durationMs": durationMs,
            "bufferedMs": bufferedMs,
            "videoCodecs": videoCodec,
            "videoMime": "",
             "videoWidth": effectiveWidth,
             "videoHeight": effectiveHeight,
             "colorTransfer": effectiveColorTransfer as Any,
            "isHdr10Plus": hdrPlus,
            "isHdr10": hdr10,
            "audioCodecs": activeAudio?.codec ?? "",
            "audioMime": "",
            "audioChannels": activeAudio?.channels ?? 0,
            "audioTracks": audioTracks,
            "selectedAudioTrack": selectedAudio,
            "subtitleLabel": activeSub?.name ?? "",
            "subtitleFormat": subtitleFormat,
            "subtitleOn": subtitleOn,
            "subtitleTracks": subtitleTracks,
            "selectedSubtitleTrack": selectedSubtitle,
            "chapters": chapters,
            "audioBoost": audioBoost,
            "nightMode": nightModeEnabled,
            "inPip": inPip,
            "error": lastError ?? "",
            "sourceScheme": currentSourceScheme,
        ]
        return map
    }

    private func emit() {
        guard let sink = eventSink else { return }
        sink(stateMap())
        updateNowPlaying()
    }

    // MARK: - Background playback (lock screen / control center)

    /// Wires lock-screen and headset transport controls to the engine. The
    /// play/seek handlers mirror the method-channel cases (`.ended` is
    /// terminal in AetherEngine — replay/scrub reloads the session).
    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        remoteCommandTokens.append(
            cc.playCommand.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                Task { @MainActor in
                    if self.engine?.state == .ended {
                        await self.reloadSession(at: 0)
                    } else {
                        self.engine?.play()
                    }
                    self.updateNowPlaying()
                }
                return .success
            })
        remoteCommandTokens.append(
            cc.pauseCommand.addTarget { [weak self] _ in
                self?.engine?.pause()
                self?.updateNowPlaying()
                return .success
            })
        remoteCommandTokens.append(
            cc.togglePlayPauseCommand.addTarget { [weak self] _ in
                guard let self, let engine = self.engine else { return .commandFailed }
                if engine.state == .playing {
                    engine.pause()
                    self.updateNowPlaying()
                    return .success
                }
                Task { @MainActor in
                    if engine.state == .ended {
                        await self.reloadSession(at: 0)
                    } else {
                        engine.play()
                    }
                    self.updateNowPlaying()
                }
                return .success
            })
        remoteCommandTokens.append(
            cc.changePlaybackPositionCommand.addTarget { [weak self] event in
                guard let self,
                      let e = event as? MPChangePlaybackPositionCommandEvent else {
                    return .commandFailed
                }
                let target = max(0, e.positionTime)
                Task { @MainActor in
                    if self.engine?.state == .ended {
                        await self.reloadSession(at: target)
                    } else {
                        await self.engine?.seek(to: target)
                    }
                    self.updateNowPlaying()
                }
                return .success
            })
    }

    /// Mirrors engine state into MPNowPlayingInfoCenter so the lock screen /
    /// control center show title + position with a live scrubber. Cleared on
    /// idle/error so a closed player doesn't linger there.
    private func updateNowPlaying() {
        guard let engine else { return }
        switch engine.state {
        case .idle, .error:
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        case .ended:
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPNowPlayingInfoPropertyPlaybackRate] = 0
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = engine.duration
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            return
        default:
            break
        }
        let playing = engine.state == .playing
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: mediaTitle ?? "DreamPlayer",
            MPMediaItemPropertyArtist: "DreamPlayer",
            MPMediaItemPropertyPlaybackDuration: max(0, engine.duration),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, engine.currentTime),
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func audioTrackMaps() -> [[String: Any]] {
        guard let engine else { return [] }
        let active = engine.activeAudioTrackIndex
        return engine.audioTracks.enumerated().map { (pos, t) in
            var m: [String: Any] = [
                "index": pos,
                "codecs": t.codec,
                "mime": "",
                "channels": t.channels,
                "bitrate": Int(t.bitrate),
                "selected": t.id == active,
            ]
            if let language = t.language, !language.isEmpty { m["language"] = language }
            if !t.name.isEmpty { m["label"] = t.name }
            return m
        }
    }

    private func subtitleTrackMaps() -> [[String: Any]] {
        guard let engine else { return [] }
        let active = engine.activeSubtitleTrackIndex
        return engine.subtitleTracks.map { t in
            var m: [String: Any] = [
                "index": t.id,
                "codecs": Self.subtitleMime(t.codec),
                "mime": "",
                "sideloaded": t.isExternal,
                "selected": t.id == active,
            ]
            if let language = t.language, !language.isEmpty { m["language"] = language }
            if !t.name.isEmpty { m["label"] = t.name }
            return m
        }
    }

    // MARK: - Subtitle overlay

    private func updateSubtitleOverlay() {
        guard let engine else { return }
        subtitleOverlay.videoSize = CGSize(width: CGFloat(videoWidth), height: CGFloat(videoHeight))
        // Apply the user's delay: positive = look for cues authored later.
        let t = engine.sourceTime - subtitleDelaySeconds
        guard let cue = engine.subtitleCues.first(where: { $0.startTime <= t && t < $0.endTime }) else {
            subtitleOverlay.clear()
            return
        }
        switch cue.body {
        case .text(let s):
            subtitleOverlay.show(text: s)
        case .richText(let runs):
            subtitleOverlay.show(text: runs.map(\.text).joined())
        case .image(let image):
            subtitleOverlay.show(image: image)
        }
    }

    // MARK: - Format helpers

    /// The Dart side detects Dolby Vision from a `dv*` codec prefix; synthesize
    /// a profile-qualified one, otherwise pass the libavcodec name through.
    private static func displayVideoCodec(base: String?, isDV: Bool, profile: Int?) -> String {
        if isDV {
            let p = profile ?? 8
            return String(format: "dvhe.%02d.06", p)
        }
        return base ?? ""
    }

    /// Media3 colorTransfer ints the Dart HDR detector understands (6 = PQ/HDR10, 7 = HLG).
    private static func colorTransfer(for format: VideoFormat) -> Int? {
        switch format {
        case .hdr10, .hdr10Plus, .dolbyVision: return 6
        case .hlg: return 7
        case .sdr: return nil
        }
    }

    /// Maps a libavcodec subtitle codec to the MIME the Dart `formatSubtitle` map knows.
    private static func subtitleMime(_ codec: String) -> String {
        switch codec.lowercased() {
        case "subrip": return "application/x-subrip"
        case "ass", "ssa": return "text/x-ssa"
        case "webvtt": return "text/vtt"
        case "mov_text": return "application/x-quicktime-tx3g"
        case "pgssub", "hdmv_pgs_subtitle": return "application/pgs"
        case "dvb_subtitle": return "application/dvb"
        default: return codec
        }
    }

    private static func subtitleFormatLabel(_ codec: String) -> String {
        switch codec.lowercased() {
        case "subrip": return "SRT"
        case "ass", "ssa": return "SSA/ASS"
        case "webvtt": return "WebVTT"
        case "mov_text": return "TX3G"
        case "pgssub", "hdmv_pgs_subtitle": return "PGS"
        case "dvb_subtitle": return "DVB"
        default: return codec.uppercased()
        }
    }

    private static func url(for s: String) -> URL? {
        if s.hasPrefix("/") { return URL(fileURLWithPath: s) }
        return URL(string: s)
    }

    // MARK: - Sidecar subtitle auto-pairing

    private static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "webvtt"]

    /// Attaches every sibling subtitle file in the video's folder (best
    /// filename-prefix match first, carrying the default selection), mirroring
    /// the Android side's auto-pairing.
    private static func siblingSubtitles(for videoURL: URL) -> [ExternalSubtitleTrack] {
        let videoBase = videoURL.deletingPathExtension().lastPathComponent.lowercased()
        let parent = videoURL.deletingLastPathComponent()
        let didAccess = parent.startAccessingSecurityScopedResource()
        defer { if (didAccess) { parent.stopAccessingSecurityScopedResource() } }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil
        ) else { return [] }

        var scored: [(score: Int, url: URL)] = []
        for f in files {
            let ext = f.pathExtension.lowercased()
            guard subtitleExtensions.contains(ext) else { continue }
            let base = f.deletingPathExtension().lastPathComponent.lowercased()
            guard base.hasPrefix(videoBase) || videoBase.hasPrefix(base) else { continue }
            var score = base == videoBase ? 200 : 100
            score += min(base.count, videoBase.count)
            scored.append((score, f))
        }
        scored.sort { $0.score > $1.score }

        return scored.prefix(12).enumerated().map { i, item in
            let f = item.url
            let base = f.deletingPathExtension().lastPathComponent
            return ExternalSubtitleTrack(
                url: f,
                name: base,
                language: languageTag(in: base),
                isForced: false,
                isHearingImpaired: false,
                isDefault: i == 0,
                formatHint: f.pathExtension.lowercased()
            )
        }
    }

    /// "House.S02E04.eng" -> "eng"; nil when the final dot-token is not a language code.
    private static func languageTag(in baseName: String) -> String? {
        guard let last = baseName.split(separator: ".").last else { return nil }
        let s = last.lowercased()
        if (s.count == 2 || s.count == 3) && s.allSatisfy({ $0.isLetter }) {
            return s
        }
        return nil
    }

    // MARK: - System volume (MPVolumeView)

    /// MPVolumeView is the only public way to set the SYSTEM volume on iOS.
    /// Its internal UISlider is built asynchronously after the view lands in a
    /// window, so we retain the view for this player's lifetime and retry the
    /// lookup with a bounded backoff — the naive synchronous `subviews.first`
    /// search always returned nil, which made the volume gesture a no-op.
    private var mpVolumeView: MPVolumeView?
    private var mpVolumeRetries = 0

    private func setSystemVolume(_ value: Float) {
        DispatchQueue.main.async {
            if self.mpVolumeView == nil {
                let mpVolume = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
                let keyWindow = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap { $0.windows }
                    .first { $0.isKeyWindow }
                keyWindow?.addSubview(mpVolume)
                self.mpVolumeView = mpVolume
                self.mpVolumeRetries = 0
            }
            guard let mpVolume = self.mpVolumeView else { return }
            if let slider = Self.findVolumeSlider(in: mpVolume) {
                slider.value = value
            } else if self.mpVolumeRetries < 20 {
                // Slider not materialized yet — retry shortly.
                self.mpVolumeRetries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.setSystemVolume(value)
                }
            }
        }
    }

    private static func findVolumeSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for sub in view.subviews {
            if let slider = findVolumeSlider(in: sub) { return slider }
        }
        return nil
    }

    // MARK: - HDR bitstream probe (mirrors Android ExoPlayerView.kt SEI scans)

    /// Scans the first ~8 MiB of `path` for HEVC SEI NALs. Best-effort: any
    /// I/O error or unknown container returns `(false,false)`.
    private static func scanHdrProbe(path: String) -> (hdr10Plus: Bool, hdr10: Bool) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return (false, false) }
        defer { try? fh.close() }
        // 8 MiB covers the SEI without pulling a whole 80 GB remux.
        let data = (try? fh.read(upToCount: 8 * 1024 * 1024)) ?? Data()
        if data.isEmpty { return (false, false) }
        let bytes = [UInt8](data)
        var foundPlus = false
        var found10 = false

        // Strict NAL-structure scan. Random compressed bytes must never be
        // able to fake an SEI, so every candidate has to clear four gates:
        //   1. Structure — Annex-B start code (MKV/TS) or a chaining AVCC
        //      length prefix (MP4/MOV).
        //   2. Codec — the stream must show HEVC parameter sets (VPS 0x40 /
        //      SPS 0x42 / PPS 0x44) and NO H.264 ones (SPS 0x67 / PPS 0x68 /
        //      IDR 0x65). H.264 MP4s are full of valid length chains whose
        //      header bytes occasionally alias HEVC types 39/40, which is how
        //      SDR phone recordings got HDR badges before this gate.
        //   3. Prefix SEI only — HDR10+/ST 2086/CLL ride NAL type 39.
        //   4. Payload-size windows — mastering display ≈ 24 B, CLL = 4 B,
        //      ST 2094-40 ≥ 4 B with the ITU-T T.35 B5 003C head.

        var sawHevc = false
        var sawH264 = false

        func noteCodec(_ b: UInt8) {
            switch b {
            case 0x40, 0x42, 0x44, 0x46: sawHevc = true
            case 0x65, 0x67, 0x68: sawH264 = true
            default: break
            }
        }

        func inspectNal(start: Int, end: Int) {
            let nalType = (Int(bytes[start]) >> 1) & 0x3F
            guard nalType == 39 else { return } // prefix SEI only
            var pos = start + 2
            while pos + 1 < end {
                var ptype = 0
                while pos < end && bytes[pos] == 0xFF { ptype += 255; pos += 1 }
                if pos >= end { break }
                ptype += Int(bytes[pos]); pos += 1
                var psize = 0
                while pos < end && bytes[pos] == 0xFF { psize += 255; pos += 1 }
                if pos >= end { break }
                psize += Int(bytes[pos]); pos += 1
                if pos + psize > end { break } // must fit inside this NAL
                if ptype == 4, psize >= 4,
                   bytes[pos] == 0xB5, bytes[pos + 1] == 0x00, bytes[pos + 2] == 0x3C {
                    foundPlus = true // ST 2094-40 (HDR10+) via ITU-T T.35
                } else if ptype == 137, psize == 24 {
                    // ST 2086: 24 B payload, sanity-check max/min luminance
                    // (DTS/AC3 bytes can fake the type+size pair — random luma
                    // values almost never fall in the HDR mastering window).
                    let b0 = Int(bytes[pos + 16]) << 24 | Int(bytes[pos + 17]) << 16
                        | Int(bytes[pos + 18]) << 8 | Int(bytes[pos + 19])
                    let b1 = Int(bytes[pos + 20]) << 24 | Int(bytes[pos + 21]) << 16
                        | Int(bytes[pos + 22]) << 8 | Int(bytes[pos + 23])
                    // maxDisplay 50..10000 nits (= 500000..100000000 in
                    // 0.0001-nit units per spec), minDisplay < maxDisplay.
                    let maxNits = UInt32(bitPattern: Int32(b0))
                    let minNits = UInt32(bitPattern: Int32(b1))
                    if maxNits >= 500_000, maxNits <= 100_000_000, minNits < maxNits {
                        found10 = true
                    }
                } else if ptype == 144, psize == 4 {
                    // content light level: 4 B (maxCLL u16 + maxFALL u16)
                    let maxCLL = Int(bytes[pos]) << 8 | Int(bytes[pos + 1])
                    let maxFALL = Int(bytes[pos + 2]) << 8 | Int(bytes[pos + 3])
                    if maxCLL >= 10, maxCLL <= 10000, maxFALL <= maxCLL {
                        found10 = true
                    }
                }
                pos += psize
                if foundPlus && found10 { return }
            }
        }

        func be32(_ i: Int) -> Int {
            (Int(bytes[i]) << 24) | (Int(bytes[i + 1]) << 16)
                | (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
        }

        var i = 0
        let limit = bytes.count - 6
        while i < limit {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                // Annex-B NAL begins after the 3-byte start code; ends at
                // the next start code (capped — real SEIs are < 4 KB).
                let s = i + 3
                if s < bytes.count { noteCodec(bytes[s]) }
                var e = s
                while e < limit {
                    if bytes[e] == 0, bytes[e + 1] == 0, bytes[e + 2] == 1 { break }
                    if e - s > 256 * 1024 { break }
                    e += 1
                }
                // Inspect unconditionally; the end-of-scan codec verdict
                // discards everything if the stream turns out H.264.
                inspectNal(start: s, end: e)
                i = s
                continue
            }
            // AVCC: u32 length at i-4, NAL header at i, and the NEXT
            // segment's length field lands exactly at i+len with another
            // sane length — three-way agreement that random bytes fail.
            if i >= 8 {
                let len = be32(i - 4)
                if len > 2, len <= bytes.count - i {
                    noteCodec(bytes[i])
                    let nt = (Int(bytes[i]) >> 1) & 0x3F
                    if nt == 39 {
                        let next = i + len
                        if next + 4 <= bytes.count {
                            let nl = be32(next)
                            if nl > 2, next + nl <= bytes.count + 4 {
                                inspectNal(start: i, end: min(next, bytes.count))
                            }
                        }
                    }
                }
            }
            i += 1
        }
        if sawH264 && !sawHevc { return (false, false) } // H.264: no HEVC SEIs exist
        return (foundPlus, found10)
    }

    // MARK: - Teardown

    private func teardownAll() {
        stopTickTimer()
        cancellables.removeAll()
        engine?.stop()
        engine?.unbind(view: engineView)
        methodChannel.setMethodCallHandler(nil)
        eventChannel.setStreamHandler(nil)
        eventSink = nil
        mpVolumeView?.removeFromSuperview()
        mpVolumeView = nil
        UIApplication.shared.isIdleTimerDisabled = false
        // Release the SMB socket. The engine has already stopped above, so the
        // demux thread is done with the reader and this close cannot race an
        // in-flight read — the ordering that crashed the retired build.
        if let token = smbToken, !token.isEmpty {
            let serverId = SMBBridge.shared.serverId(forToken: token)
            // Releasing the latch also closes the socket, so no separate
            // closePlayback call is needed (and none should race this one).
            SMBBridge.shared.setPlayerActive(false, serverId: serverId)
        }
        smbToken = nil
        isSMBStream = false
    }

    // MARK: - SMB helpers

    /// Logs an engine error once per distinct message. The error state sticks,
    /// so emit() repeats it ~10x a second and an unfiltered log filled up with
    /// identical lines within seconds.
    private func logErrorOnce(_ message: String) {
        if message == lastLoggedError { return }
        lastLoggedError = message
        SBMLog.log("engine error: \(message)")
    }

    /// `smb:<serverId>/<share>/<path>` split into its parts.
    ///
    /// This is the durable handle on an SMB file. A `dreamplayersmb://` token
    /// is NOT: it is minted per playback session, so a resumed or
    /// Continue-Watching item carries a token whose connection died with the
    /// previous run. Resuming therefore has to go through the resume key.
    private static func smbParts(fromResumeKey key: String?) -> (id: String, share: String, path: String)? {
        guard let key, key.hasPrefix("smb:") else { return nil }
        let rest = String(key.dropFirst(4))
        let segments = rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count >= 2, !segments[0].isEmpty, !segments[1].isEmpty else { return nil }
        return (segments[0], segments[1], segments.dropFirst(2).joined(separator: "/"))
    }


    /// Extension from a `dreamplayersmb://<token>.<ext>` URL, or "".
    private static func smbTokenExtension(_ urlString: String) -> String {
        let tail = urlString.dropFirst("dreamplayersmb://".count)
        let ext = (tail as NSString).pathExtension.lowercased()
        // A token is `<serverId>-<n>`; anything that looks like a real
        // extension is one, anything else means the NAS file had no extension.
        guard !ext.isEmpty, ext.count <= 5, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return ""
        }
        return ext
    }

    /// Guess the container for an extensionless NAS file by reading its first
    /// bytes. FFmpeg's custom-source probe fails outright on a hint-less
    /// source, so an extensionless file would otherwise never open.
    /// libsmb2 playback variant. `readAtOffset` is already synchronous and
    /// positional, so the head read needs no Task and no semaphore — the two
    /// constructs `readSyncHead` needs for an async ByteRangeSource.
    private static func sniffFormatFromSMB(_ file: LibSMB2File) -> String? {
        sniffContainerFormat(head: file.read(atOffset: 0, length: 16))
    }

    private static func sniffFormatFromSMB(_ source: ByteRangeSource) -> String? {
        sniffContainerFormat(head: try? readSyncHead(source))
    }

    /// Magic-byte container guess, shared by the SMB transports.
    private static func sniffContainerFormat(head: Data?) -> String? {
        guard let head else { return nil }
        func starts(_ bytes: [UInt8]) -> Bool {
            guard head.count >= bytes.count else { return false }
            return Array(head.prefix(bytes.count)) == bytes
        }
        if starts([0x1A, 0x45, 0xDF, 0xA3]) { return "matroska" }   // MKV/WebM
        if head.count >= 12, String(data: head.prefix(12), encoding: .ascii)?
            .hasPrefix("RIFF") == true, head.count >= 8,
           String(data: head[8..<12], encoding: .ascii) == "AVI " { return "avi" }
        if starts([0x66, 0x74, 0x79, 0x70]) { return "mp4" }        // ftyp
        if head.count >= 4, head[0] == 0x47, head[1] == 0x00 { return "mpegts" }
        if starts([0x47]) { return "mpegts" }
        if starts([0xFF, 0xD8, 0xFF]) { return "mjpeg" }          // many .ts/.m2ts
        if starts([0x25, 0x50, 0x44, 0x46]) { return "pdf" }      // not video; ignore
        if head.count >= 12, String(data: head.prefix(12), encoding: .ascii)?
            .hasPrefix("RIFF") == true { return "wav" }
        return nil
    }

    /// Holder for the sniff read. A class, not a captured `var`: mutating a
    /// captured local from a Task trips Swift 6 strict concurrency, and the
    /// semaphore's signal/wait is the happens-before edge.
    private final class HeadRead: @unchecked Sendable {
        var data: Data?
        init() {}
    }

    /// Blocking read of the first bytes, for the sniff above only.
    private static func readSyncHead(_ source: ByteRangeSource) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        let out = HeadRead()
        Task.detached(priority: .userInitiated) {
            out.data = try? await source.read(at: 0, length: 16)
            semaphore.signal()
        }
        semaphore.wait()
        return out.data
    }
}


// MARK: - PictureInPictureControllerDelegate

extension AvPlayerView: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStart(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        inPip = true
        emit()
    }

    func pictureInPictureControllerDidStop(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        inPip = false
        emit()
        // Re-arm defensively (no-op when the controller is still bound to a
        // live layer) so the next HOME swipe floats again.
        ensurePipController()
    }

    /// User tapped the restore button on the pip window — the layer is back
    /// inline. The controller stays valid while its AVPlayerLayer keeps the
    /// same player, so it is NOT nilled here: nil-ing left no controller for
    /// the next HOME swipe (auto-start silently did nothing and the app just
    /// minimized). A new load replaces the controller via
    /// [invalidatePipController] + [ensurePipController].
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

// MARK: - Style helpers

private extension Double {
    func clamped(_ range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension UIColor {
    /// ARGB int from the Dart side (alpha in the top byte).
    convenience init(argb: Int) {
        self.init(
            red: CGFloat((argb >> 16) & 0xFF) / 255.0,
            green: CGFloat((argb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(argb & 0xFF) / 255.0,
            alpha: CGFloat((argb >> 24) & 0xFF) / 255.0
        )
    }}
