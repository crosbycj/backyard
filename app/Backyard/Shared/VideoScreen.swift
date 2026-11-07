import AVKit
import UIKit

/// A video, fullscreen, looping. It opens on the photo it grew out of; the
/// video waits at that same instant and fades in over it once its frame is
/// ready, so the photo seems to come to life. Nothing covers it: in the room
/// under the video are three glass controls, play, a dial to turn with
/// your thumb, and mute. Tap the video to hide them (and again to bring
/// them back). Swipe down to put it back.
final class VideoScreen: UIViewController, UIGestureRecognizerDelegate {
    /// Where it stopped, in seconds, as it goes away.
    var onClose: ((Double) -> Void)?

    private let player: AVPlayer
    private let still: UIImage?
    private let start: Double
    private let moments: [Double]
    private let stillView = UIImageView()
    private let frames: FrameView
    private let controls = UIView()
    private let playButton = UIButton(type: .system)
    private let muteButton = UIButton(type: .system)
    private let scrubber = Scrubber()
    /// What you hear while you turn the dial.
    private let scrubAudio = ScrubAudio()
    private var readiness: NSKeyValueObservation?
    private var ended: NSObjectProtocol?
    private var ticks: Any?
    private var duration: Double = 0
    private var atStart = false
    /// Playing when a scrub began, so letting go plays on.
    private var resumeAfterScrub = false
    private var scrubbing = false
    private var seeking = false
    private var nextSeek: Double?

    /// Sound is on unless you've turned it off here; the app remembers.
    private static let mutedKey = "video.muted"
    private static var muted: Bool {
        get { UserDefaults.standard.bool(forKey: mutedKey) }
        set { UserDefaults.standard.set(newValue, forKey: mutedKey) }
    }

    /// `moments`: where the visit's photos were taken, in seconds, marked on
    /// the filmstrip.
    init(player: AVPlayer, still: UIImage?, start: Double, moments: [Double] = []) {
        self.player = player
        self.still = still
        self.start = start
        self.moments = moments
        frames = FrameView(player: player)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Grows out of `source` and shrinks back into it; a swipe down puts it
    /// back, except on the controls (a scrub that wanders isn't a dismiss).
    func zoom(from source: @escaping () -> UIView?) {
        let options = UIViewController.Transition.ZoomOptions()
        options.interactiveDismissShouldBegin = { [weak self] context in
            guard let self, abs(context.velocity.dy) > abs(context.velocity.dx) else { return false }
            return controls.alpha == 0 || !controls.frame.insetBy(dx: -8, dy: -12).contains(context.location)
        }
        preferredTransition = .zoom(options: options) { _ in source() }
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // Over the video, the glass and anything else drawn are for the dark.
        overrideUserInterfaceStyle = .dark
        stillView.image = still
        stillView.contentMode = .scaleAspectFit
        view.pin(stillView)
        frames.playerLayer.videoGravity = .resizeAspect
        frames.backgroundColor = .clear
        view.pin(frames)
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        tap.delegate = self
        view.addGestureRecognizer(tap)

        playButton.addAction(UIAction { [weak self] _ in self?.togglePlay() }, for: .primaryActionTriggered)
        muteButton.addAction(UIAction { [weak self] _ in self?.toggleMute() }, for: .primaryActionTriggered)
        scrubber.moments = moments
        scrubber.onScrub = { [weak self] seconds, phase in self?.scrub(to: seconds, phase) }
        [playButton, scrubber, muteButton].forEach(controls.addSubview)
        controls.alpha = 0
        view.addSubview(controls)
        showPlaying(true)
        showMuted()

        // The video shows only once it's at the photo's instant and its
        // frame is ready, over the photo.
        readiness = frames.playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.reveal() }
        }
        // Round and round: a visit is a minute, a reel half that.
        ended = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                       object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? AVPlayerItem === self.player.currentItem, !self.scrubbing else { return }
                self.player.seek(to: .zero) { _ in Task { @MainActor in self.player.play() } }
            }
        }
        ticks = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.scrubbing, !self.seeking else { return }
                self.scrubber.show(time.seconds)
            }
        }
        if let asset = player.currentItem?.asset {
            Task { [weak self] in
                guard let time = try? await asset.load(.duration), time.seconds.isFinite, time.seconds > 0 else { return }
                self?.duration = time.seconds
                await self?.scrubber.load(asset, at: self?.start ?? 0)
                await self?.scrubAudio.load(asset)
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // In the room under the video (Bird Buddy's are 3:4, so there's
        // plenty); over its foot if a wide one leaves none.
        let aspect = player.currentItem?.presentationSize ?? still?.size ?? CGSize(width: 3, height: 4)
        let video = AVMakeRect(aspectRatio: aspect.width > 0 ? aspect : CGSize(width: 3, height: 4), insideRect: view.bounds)
        let height: CGFloat = 54
        let floor = view.bounds.height - max(view.safeAreaInsets.bottom, 16)
        let room = floor - video.maxY
        let y = room >= height + 16 ? video.maxY + (room - height) / 2 : floor - height - 8
        controls.frame = CGRect(x: 16, y: y, width: view.bounds.width - 32, height: height)
        playButton.frame = CGRect(x: 0, y: 0, width: height, height: height)
        muteButton.frame = CGRect(x: controls.bounds.width - height, y: 0, width: height, height: height)
        scrubber.frame = CGRect(x: height + 10, y: 0, width: controls.bounds.width - 2 * (height + 10), height: height)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        CallPlayer.shared.stop()
        // Sound on, the silent switch notwithstanding; mute is right here.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.isMuted = Self.muted
        // From the photo's own instant, playing while the photo grows.
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.atStart = true
                self.player.play()
                self.reveal()
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIView.animate(withDuration: 0.25) { self.controls.alpha = 1 }
    }

    /// Fade the video in over the photo, once both are true: it has jumped
    /// to the photo's instant, and that frame can be shown.
    private func reveal() {
        guard atStart, frames.playerLayer.isReadyForDisplay, frames.alpha == 0 else { return }
        UIView.animate(withDuration: 0.18, delay: 0.05) { self.frames.alpha = 1 }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isBeingDismissed else { return }
        player.pause()
        player.isMuted = false
        UIView.animate(withDuration: 0.12) { self.controls.alpha = 0 }
        onClose?(player.currentTime().seconds)
    }

    deinit {
        ended.map(NotificationCenter.default.removeObserver)
        if let ticks { player.removeTimeObserver(ticks) }
    }

    // MARK: - Controls

    /// The video's own taps: show or hide the controls (not on the controls).
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view?.isDescendant(of: controls) ?? false)
    }

    @objc private func toggleControls() {
        let show = controls.alpha < 0.5
        UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.controls.alpha = show ? 1 : 0
        }
    }

    private func togglePlay() {
        let playing = player.timeControlStatus != .paused
        playing ? player.pause() : player.play()
        showPlaying(!playing)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func showPlaying(_ playing: Bool) {
        playButton.configuration = Glass.button(symbol: playing ? "pause.fill" : "play.fill", size: 19)
        playButton.accessibilityLabel = playing ? "Pause" : "Play"
    }

    private func toggleMute() {
        Self.muted.toggle()
        player.isMuted = Self.muted
        showMuted()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func showMuted() {
        muteButton.configuration = Glass.button(symbol: Self.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 17)
        muteButton.accessibilityLabel = Self.muted ? "Turn sound on" : "Mute"
    }

    private func scrub(to seconds: Double, _ phase: Scrubber.Phase) {
        guard duration > 0 else { return }
        let at = min(max(seconds, 0), duration)
        switch phase {
        case .began:
            // Caught again mid-fling: still the same scrub.
            if !scrubbing { resumeAfterScrub = player.timeControlStatus != .paused }
            scrubbing = true
            player.pause()
            seek(at)
        case .moved:
            seek(at)
            if !Self.muted { scrubAudio.play(at: at) }
        case .ended:
            scrubbing = false
            scrubAudio.stop()
            seek(at)
            if resumeAfterScrub { player.play() }
            showPlaying(resumeAfterScrub)
        }
    }

    /// Frame-exact, and never more than one seek at a time: while one is
    /// under way, only the latest place asked for waits its turn.
    private func seek(_ seconds: Double) {
        guard !seeking else { nextSeek = seconds; return }
        seeking = true
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seeking = false
                if let next = self.nextSeek {
                    self.nextSeek = nil
                    self.seek(next)
                }
            }
        }
    }
}

/// The video as a dial: a ruler of its seconds, in glass, sliding under a
/// line that stays put. Drag it anywhere and it moves with your thumb, a
/// second for every few points, so it's easy to land on a frame; fling it
/// and it runs on and slows, scrubbing as it goes. A dot marks each photo,
/// and you feel a tick as one passes the line.
final class Scrubber: UIView, UIScrollViewDelegate {
    enum Phase { case began, moved, ended }

    /// The time under the line, in seconds, as you turn it.
    var onScrub: ((Double, Phase) -> Void)?
    /// The photos' places, in seconds.
    var moments: [Double] = []

    /// How far the strip moves for a second of video: fine enough to land
    /// on a frame, short enough that a fling crosses a visit.
    private static let pointsPerSecond: CGFloat = 14
    private static let inset: CGFloat = 5

    private let glass: UIVisualEffectView
    private let opening = UIView()
    private let fade = CAGradientLayer()
    private let scroll = UIScrollView()
    private let strip = UIView()
    private let head = UIView()
    private var dots: [UIView] = []
    private var length: Double = 0
    /// A mark for every second, taller every five.
    private let ruler = CAShapeLayer()
    private var lastTime: Double = 0
    private let tick = UISelectionFeedbackGenerator()

    override init(frame: CGRect) {
        if #available(iOS 26.0, *) {
            glass = UIVisualEffectView(effect: UIGlassEffect())
        } else {
            glass = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        }
        super.init(frame: frame)
        glass.isUserInteractionEnabled = false
        glass.clipsToBounds = true
        glass.layer.cornerCurve = .continuous
        addSubview(glass)
        // The strip fades out toward the ends, like a dial turning away.
        opening.clipsToBounds = true
        opening.layer.cornerCurve = .continuous
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [UIColor.clear, .black, .black, .clear].map(\.cgColor)
        fade.locations = [0, 0.14, 0.86, 1]
        opening.layer.mask = fade
        addSubview(opening)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.decelerationRate = .normal
        scroll.delegate = self
        scroll.contentInsetAdjustmentBehavior = .never
        opening.addSubview(scroll)
        ruler.strokeColor = UIColor.white.withAlphaComponent(0.55).cgColor
        ruler.lineWidth = 1.5
        ruler.lineCap = .round
        strip.layer.addSublayer(ruler)
        scroll.addSubview(strip)
        head.backgroundColor = .white
        head.layer.shadowColor = UIColor.black.cgColor
        head.layer.shadowOpacity = 0.5
        head.layer.shadowRadius = 3
        head.layer.shadowOffset = .zero
        head.isUserInteractionEnabled = false
        addSubview(head)
        isAccessibilityElement = true
        accessibilityLabel = "Video position"
        accessibilityTraits = .adjustable
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The time under the line.
    private var time: Double {
        Double((scroll.contentOffset.x + scroll.contentInset.left) / Self.pointsPerSecond)
    }

    /// Turn the dial to `seconds` (as it plays), unless a thumb has it.
    func show(_ seconds: Double) {
        guard !scroll.isTracking, !scroll.isDecelerating, length > 0 else { return }
        lastTime = seconds
        scroll.contentOffset.x = CGFloat(seconds) * Self.pointsPerSecond - scroll.contentInset.left
    }

    /// Lay the video along the dial.
    func load(_ asset: AVAsset, at start: Double) async {
        length = (try? await asset.load(.duration).seconds) ?? 0
        guard length > 0 else { return }
        setNeedsLayout()
        layoutIfNeeded()
        placeDots()
        show(start)
    }

    private func placeDots() {
        dots.forEach { $0.removeFromSuperview() }
        dots = moments.filter { $0 >= 0 && $0 <= length }.map { moment in
            let dot = UIView()
            dot.backgroundColor = .white
            dot.layer.cornerRadius = 3
            dot.layer.shadowColor = UIColor.black.cgColor
            dot.layer.shadowOpacity = 0.7
            dot.layer.shadowRadius = 2
            dot.layer.shadowOffset = .zero
            dot.frame = CGRect(x: CGFloat(moment) * Self.pointsPerSecond - 3, y: strip.bounds.height / 2 - 3, width: 6, height: 6)
            strip.addSubview(dot)
            return dot
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        glass.layer.cornerRadius = bounds.height / 2
        let inner = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        opening.frame = inner
        opening.layer.cornerRadius = inner.height / 2
        fade.frame = opening.bounds
        let keep = time
        scroll.frame = opening.bounds
        // Half the window of room at each end, so the start and the end can
        // each come to the line.
        let half = inner.width / 2
        scroll.contentInset = UIEdgeInsets(top: 0, left: half, bottom: 0, right: half)
        let width = max(CGFloat(length) * Self.pointsPerSecond, 1)
        strip.frame = CGRect(x: 0, y: 0, width: width, height: inner.height)
        scroll.contentSize = strip.bounds.size
        drawRuler()
        if length > 0, !scroll.isTracking, !scroll.isDecelerating {
            scroll.contentOffset.x = CGFloat(keep) * Self.pointsPerSecond - half
        }
        let tracking = scroll.isTracking
        let w: CGFloat = tracking ? 4.5 : 3.5
        head.bounds = CGRect(x: 0, y: 0, width: w, height: bounds.height + (tracking ? 8 : 2))
        head.layer.cornerRadius = w / 2
        head.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private func drawRuler() {
        let h = strip.bounds.height
        guard length > 0, h > 0 else { ruler.path = nil; return }
        let path = UIBezierPath()
        for second in 0...Int(length) {
            let x = CGFloat(second) * Self.pointsPerSecond
            let tall: CGFloat = second % 5 == 0 ? h * 0.46 : h * 0.24
            path.move(to: CGPoint(x: x, y: (h - tall) / 2))
            path.addLine(to: CGPoint(x: x, y: (h + tall) / 2))
        }
        ruler.frame = strip.bounds
        ruler.path = path.cgPath
    }

    // MARK: - Turning it

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        tick.prepare()
        lastTime = time
        UIView.animate(withDuration: 0.15) { self.setNeedsLayout(); self.layoutIfNeeded() }
        onScrub?(clamped, .began)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isTracking || scrollView.isDecelerating else { return }
        let now = time
        // A tick as a photo passes the line.
        let (low, high) = (min(lastTime, now), max(lastTime, now))
        if moments.contains(where: { $0 > low && $0 <= high }) { tick.selectionChanged() }
        lastTime = now
        onScrub?(clamped, .moved)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finish() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finish() }

    private func finish() {
        UIView.animate(withDuration: 0.2) { self.setNeedsLayout(); self.layoutIfNeeded() }
        onScrub?(clamped, .ended)
    }

    private var clamped: Double { min(max(time, 0), length) }

    override func accessibilityIncrement() { step(2) }
    override func accessibilityDecrement() { step(-2) }

    private func step(_ by: Double) {
        let to = min(max(time + by, 0), length)
        show(to)
        onScrub?(to, .began)
        onScrub?(to, .ended)
    }
}

/// Apple's Liquid Glass for small round controls over photos, where the
/// system has it (iOS 26); frosted material before that. Its symbol and
/// words are never a fixed color: the glass makes them dark over a bright
/// sky and light over a dark one, like the bar's own buttons beside it.
enum Glass {
    static func button(symbol: String, size: CGFloat = 15, title: String? = nil) -> UIButton.Configuration {
        var config: UIButton.Configuration
        if #available(iOS 26.0, *) {
            config = .glass()
        } else {
            config = .gray()
            config.background.visualEffect = UIBlurEffect(style: .systemThinMaterial)
            config.background.backgroundColor = .clear
        }
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold))
        config.title = title
        config.imagePadding = 6
        config.cornerStyle = .capsule
        config.baseForegroundColor = .label
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = Style.weight(Style.footnote, .semibold); return a
        }
        return config
    }

    /// A few words in glass, not a control: "3 of 7".
    static func label(_ text: String) -> UIButton.Configuration {
        var config = button(symbol: "", title: text)
        config.image = nil
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        return config
    }
}
