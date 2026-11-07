import AVKit
import Photos
import UIKit
import YardModel
import YardStore

/// One visit: its photos at the top, which shrink as you read down and stay
/// in view, then what Claude saw, then Ask Claude, then the bird: more of
/// it, its page, its call and where to read about it. The ⋯ menu saves,
/// corrects, shares and asks Claude.
final class VisitViewController: UIViewController, UIScrollViewDelegate {
    let visitID: String
    private var visit: Visit
    private let pages: [Media]
    private let start: Int
    private let pager: MediaPager
    private let scroll = UIScrollView()
    private let words = UIStackView()
    /// On the photo: a glass play button (when there's a video) and "3 of 7".
    private let play = UIButton(type: .system)
    private let counter = UIButton(type: .system)
    private var fullHeight: CGFloat = 0
    /// The visit's minute of video, and where each photo falls in it.
    private let video: VisitVideo?
    private let moments: [Double]
    private var frames: FrameView?
    private var loop: Any?

    init(visit: Visit, startAt media: String?) {
        self.visit = visit
        visitID = visit.id
        // The photos (Claude's stills from the video among them), in the order
        // they were taken. The video isn't a page: it's the minute they're in.
        pages = visit.photos
        start = pages.firstIndex { $0.id == (media ?? visit.best) } ?? 0
        pager = MediaPager(pages: pages, poster: nil)
        video = VisitVideo(visit)
        moments = pages.map { visit.moment(of: $0) ?? 0 }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Style.page

        scroll.alwaysBounceVertical = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delegate = self
        view.pin(scroll)

        words.axis = .vertical
        words.spacing = 14
        words.isLayoutMarginsRelativeArrangement = true
        words.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 18, leading: Style.gutter,
                                                                 bottom: 48, trailing: Style.gutter)
        words.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(words)
        NSLayoutConstraint.activate([
            words.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            words.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            words.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            words.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            words.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])

        // The pager sits over the top of the scroll view, laid out by hand as it shrinks.
        addChild(pager)
        view.addSubview(pager.view)
        pager.didMove(toParent: self)
        pager.onPage = { [weak self] page in self?.showCounter(page) }
        pager.scroll(to: start)
        if let video {
            // The video's frames in the photo's place, while you hold it.
            let frames = FrameView(player: video.player)
            view.addSubview(frames)
            self.frames = frames
            play.configuration = Glass.button(symbol: "play.fill", size: 17)
            play.configuration?.contentInsets = .zero
            play.accessibilityLabel = "Play the video from this photo"
            play.addAction(UIAction { [weak self] _ in self?.playFullscreen() }, for: .primaryActionTriggered)
            view.addSubview(play)
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(held))
            hold.minimumPressDuration = 0.35
            pager.view.addGestureRecognizer(hold)
        }
        counter.isUserInteractionEnabled = false
        view.addSubview(counter)
        showCounter(start)

        // The words below the photo come a moment later: a card starts
        // growing out of its photo first, and they fill in as it grows.
        DispatchQueue.main.async { [weak self] in self?.build() }
        NotificationCenter.default.addObserver(forName: YardStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: CallPlayer.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.build() }
        }
    }

    /// Its card is showing this visit now: its title and menu go in the card's bar.
    func becameCurrent(of host: VisitPages) {
        loadViewIfNeeded()
        host.showTitle(for: visit)
        host.navigationItem.rightBarButtonItems = barItems()
        // So play starts the moment it's tapped (after the card's first frame).
        DispatchQueue.main.async { [weak self] in self?.video?.prepare() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Leaving the visit (not going fullscreen) stops its video.
        if presentedViewController == nil { video?.player.pause() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // As tall as the photo is (Bird Buddy's are 3:4; a shared one is wide),
        // leaving some of the words in view. A wide photo sits below the bar.
        let aspect = max((visit.bestPhoto ?? pages.first)?.aspect ?? 0.75, 0.5)
        let under = aspect > 1 ? view.safeAreaInsets.top : 0
        let full = min(view.bounds.width / aspect + under, view.bounds.height * 0.6)
        if full != fullHeight {
            fullHeight = full
            pager.pageHeight = full
            scroll.contentInset.top = full
            scroll.verticalScrollIndicatorInsets.top = full
            scroll.contentOffset.y = -full
        }
        layoutPager()
    }

    /// The photos shrink to a band as you scroll down. (Pulling down past
    /// the top puts the card away.)
    private func layoutPager() {
        let down = max(scroll.contentOffset.y + fullHeight, 0)
        let collapsed = min(fullHeight, max(view.bounds.width * 0.5, view.safeAreaInsets.top + 120))
        let height = max(collapsed, fullHeight - down)
        pager.view.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: height)
        pager.pageHeight = fullHeight
        frames?.frame = pager.view.frame
        // Both at the photo's bottom, on one line, as far in as the bar's buttons.
        play.frame = CGRect(x: 16, y: height - 44 - 14, width: 44, height: 44)
        let size = counter.intrinsicContentSize
        counter.frame = CGRect(x: view.bounds.width - size.width - 16, y: play.frame.midY - 16,
                               width: size.width, height: 32)
    }

    // MARK: - The video

    /// The photo nearest a moment in the video.
    private func photo(nearest seconds: Double) -> Int {
        moments.indices.min { abs(moments[$0] - seconds) < abs(moments[$1] - seconds) } ?? 0
    }

    private func showFrames(_ on: Bool) {
        UIView.animate(withDuration: on ? 0.08 : 0.2) { self.frames?.alpha = on ? 1 : 0 }
    }

    /// The photo grows to fill the screen and comes to life: the video
    /// plays from the instant the photo was taken, with nothing over it.
    func playFullscreen() {
        guard let video, presentedViewController == nil else { return }
        video.prepare()
        let from = moments.indices.contains(pager.current) ? max(0, moments[pager.current]) : 0
        let screen = VideoScreen(player: video.player, still: pager.currentImage, start: from, moments: moments)
        screen.zoom { [weak self] in self?.pager.view }
        screen.onClose = { [weak self] seconds in self?.settle(at: seconds) }
        present(screen, animated: true)
    }

    /// Back from fullscreen: on the photo nearest where it stopped, so it
    /// shrinks back into that photo.
    private func settle(at seconds: Double) {
        let nearest = photo(nearest: seconds)
        pager.show(page: nearest)
        showCounter(nearest)
    }

    /// Holding a photo plays the few seconds around it, silently, over and
    /// over, like a Live Photo; letting go stops.
    @objc private func held(_ hold: UILongPressGestureRecognizer) {
        guard let video else { return }
        let m = moments.indices.contains(pager.current) ? moments[pager.current] : 0
        let from = max(0, m - 1), to = m + 2
        switch hold.state {
        case .began:
            video.prepare()
            video.player.isMuted = true
            showFrames(true)
            video.player.seek(to: CMTime(seconds: from, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                Task { @MainActor in video.player.play() }
            }
            loop = video.player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: to, preferredTimescale: 600))],
                                                        queue: .main) {
                video.player.seek(to: CMTime(seconds: from, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .ended, .cancelled, .failed:
            if let loop { video.player.removeTimeObserver(loop) }
            loop = nil
            video.player.pause()
            video.player.isMuted = false
            showFrames(false)
        default: break
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { layoutPager() }

    // MARK: - What it says

    /// A newer word on this visit (a sync, a correction) rebuilds the words.
    private func refresh() {
        if let fresh = try? Yard.store.visit(visitID) { visit = fresh }
        if let host = parent as? VisitPages, host.viewControllers?.first === self {
            host.navigationItem.rightBarButtonItems = barItems()
        }
        build()
    }

    private func build() {
        words.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let day = Yard.calendar.day(of: visit.at)
        let bird = visit.bird?.bird.flatMap { try? Yard.store.bird($0) }

        // The day it happened, a door to the journal there.
        var dayConfig = UIButton.Configuration.plain()
        dayConfig.title = "\(Words.longDate.string(from: visit.at)) at \(Words.clockWithHalf.string(from: visit.at))"
        dayConfig.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption2)
            .applying(UIImage.SymbolConfiguration(weight: .semibold)))
        dayConfig.imagePlacement = .trailing
        dayConfig.imagePadding = 4
        dayConfig.baseForegroundColor = Style.soft
        dayConfig.contentInsets = .zero
        dayConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = Style.footnote; return a
        }
        let dateline = UIButton(configuration: dayConfig, primaryAction: UIAction { [weak self] _ in
            self?.openJournal(at: day)
        })
        dateline.contentHorizontalAlignment = .leading
        words.addArrangedSubview(dateline)
        words.setCustomSpacing(6, after: dateline)

        if let caption = visit.caption {
            let font = Style.weight(Style.title, .regular)
            let label = UILabel(font: font)
            label.attributedText = Words.bolded(caption, font: font, lineHeight: 1.08)
            words.addArrangedSubview(label)
            words.setCustomSpacing(12, after: label)
        }
        if let notes = visit.notes {
            let label = UILabel(font: Style.prose)
            label.attributedText = Words.bolded(notes, font: Style.prose, lineHeight: Style.proseLeading)
            words.addArrangedSubview(label)
            words.setCustomSpacing(8, after: label)
        }
        let byline = UILabel(font: Style.footnote, color: Style.soft)
        let written = visit.writtenAt.map { ", \(Words.shortDay.string(from: $0)) at \(Words.clockWithHalf.string(from: $0))" } ?? ""
        byline.text = (visit.by == "owner"
            ? "Corrected by you; words by Claude\(written)."
            : "Seen by \(Words.author(visit.by))\(written), from the photos alone.")
            + (visit.number.map { " Visit \($0) in the archive." } ?? "")
        words.addArrangedSubview(byline)
        words.setCustomSpacing(24, after: byline)

        if let pending = try? Yard.store.pendingCorrection(of: visit) {
            let note = UILabel(font: Style.subheadline)
            note.attributedText = Words.bolded(
                "You said this is a **\(pending.name)**. Claude rewrites this visit on the collector's next run, and the board and the story follow.",
                font: Style.subheadline, lineHeight: 1.1)
            let icon = UIImageView(image: UIImage(systemName: "pencil.circle.fill"))
            icon.tintColor = Style.accent
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let row = UIStackView(arrangedSubviews: [icon, note])
            row.spacing = 10
            row.alignment = .firstBaseline
            let panel = Panel([row])
            words.addArrangedSubview(panel)
            words.setCustomSpacing(12, after: panel)
        }

        // Who came, each with its face: a door to the bird.
        if !visit.birds.isEmpty {
            let rows = visit.birds.enumerated().map { i, sighting in self.sighting(sighting, own: i == 0) }
            let seen = Panel.rows(rows)
            words.addArrangedSubview(seen)
            words.setCustomSpacing(12, after: seen)
        }

        var actions: [ActionTiles.Action] = [
            .init(title: "Ask Claude", symbol: "sparkle") { [weak self] in
                self?.askClaude("Tell me more about this visit.", page: self?.visit.page)
            },
        ]
        if let call = bird?.call {
            let playing = CallPlayer.shared.playing == call.url
            actions.append(.init(title: playing ? "Stop" : "Its call", symbol: playing ? "stop.fill" : "waveform") {
                CallPlayer.shared.toggle(call.url)
            })
        }
        actions.append(.init(title: bird.map { "Not a \(Words.shortName($0.name))?" } ?? "Correct", symbol: "pencil") { [weak self] in
            self?.correct()
        })
        actions.append(.init(title: "Share", symbol: "square.and.arrow.up") { [weak self] in self?.share() })
        words.addArrangedSubview(ActionTiles(actions))

        if let bird { about(bird) }
    }

    /// A bird that came, with its face (this visit's own, for the bird the
    /// photo is of), how sure Claude is, and what it noticed.
    private func sighting(_ bird: Sighting, own: Bool) -> SightingRow {
        let face = FaceView(size: 56)
        if own, visit.box != nil { face.show(visit: visit) } else { face.show(bird: bird.bird) }
        return SightingRow(bird, face: face) { [weak self] in self?.open(bird: bird.bird) }
    }

    /// The bird: its other visits as photos, and the way to all of it.
    private func about(_ bird: Bird) {
        let others = ((try? Yard.store.visits(Lens(bird: bird.key))) ?? [])
            .filter { $0.source != .report && $0.bestPhoto != nil }
        let rest = others.filter { $0.id != visit.id }
        guard !rest.isEmpty else { return }
        words.setCustomSpacing(32, after: words.arrangedSubviews.last!)
        words.addArrangedSubview(SectionTitle("More of the \(Words.shortName(bird.name))"))
        words.addArrangedSubview(VisitStrip(visits: Array(rest.prefix(16))) { [weak self] other, photo in
            self?.open(visit: other, among: others, from: photo)
        })
        let face = FaceView(size: 32)
        face.show(bird: bird.key)
        words.addArrangedSubview(Panel.rows([DoorRow(bird.name, detail: Words.count(bird.photographed, "visit") + " with photos",
                                                     leading: face) { [weak self] in self?.open(bird: bird.key) }]))
    }

    /// "3 of 7", in glass, when there's more than one photo.
    private func showCounter(_ page: Int) {
        guard pages.indices.contains(page), pages.count > 1 else { counter.isHidden = true; return }
        counter.isHidden = false
        counter.configuration = Glass.label("\(page + 1) of \(pages.count)")
        if fullHeight > 0 { layoutPager() }
    }

    // MARK: - The menu

    private var saved: Bool { (try? Yard.store.isKept(visit.id)) ?? false }

    private func barItems() -> [UIBarButtonItem] {
        let save = UIBarButtonItem(image: UIImage(systemName: saved ? "heart.fill" : "heart"),
                                   primaryAction: UIAction { [weak self] _ in self?.toggleSaved() })
        save.accessibilityLabel = saved ? "Favorite" : "Add to Favorites"
        let name = visit.bird?.name ?? "this bird"
        let menu = UIMenu(children: [
            UIAction(title: saved ? "Remove from Favorites" : "Add to Favorites", image: UIImage(systemName: saved ? "heart.slash" : "heart")) { [weak self] _ in
                self?.toggleSaved()
            },
            UIAction(title: "Not a \(Words.shortName(name))? Correct it", image: UIImage(systemName: "pencil")) { [weak self] _ in
                self?.correct()
            },
            UIAction(title: "Ask Claude about this visit", image: UIImage(systemName: "sparkle")) { [weak self] _ in
                self?.askClaude("Tell me more about this visit.", page: self?.visit.page)
            },
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Save photo to Photos", image: UIImage(systemName: "photo.badge.arrow.down")) { [weak self] _ in
                    self?.saveToPhotos(video: false)
                },
            ] + (visit.video == nil ? [] : [
                UIAction(title: "Save video to Photos", image: UIImage(systemName: "video.badge.arrow.down")) { [weak self] _ in
                    self?.saveToPhotos(video: true)
                },
            ]) + [
                UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                    self?.share()
                },
            ]),
        ])
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: menu)
        more.accessibilityLabel = "More"
        return [more, save]
    }

    private func toggleSaved() {
        try? Yard.store.setKept(!saved, Mark(visit: visit.id))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Yard.sendMarks()
    }

    func correct() {
        let sheet = CorrectViewController(visit: visit)
        let nav = UINavigationController(rootViewController: sheet)
        nav.sheetPresentationController?.detents = [.medium(), .large()]
        nav.sheetPresentationController?.prefersGrabberVisible = true
        present(nav, animated: true)
    }

    /// The photo on screen (or the visit's video) into Photos.
    func saveToPhotos(video: Bool) {
        VisitActions.save(visit, photo: pager.currentMedia, video: video, from: self)
    }

    private func share() {
        VisitActions.share(visit, image: pager.currentImage, from: self)
    }

    /// Whether the visit is scrolled to its top, so a swipe down can put it away.
    var atTop: Bool { !isViewLoaded || scroll.contentOffset.y <= -fullHeight + 4 }

    /// Where the photo showing is drawn, uncropped, in `other`'s points:
    /// what its card lines up with the photo it grew out of.
    func pictureFrame(in other: UIView, aspect: CGFloat) -> CGRect? {
        pager.pictureFrame(in: other, aspect: aspect)
    }

    var photoShowing: String? { pager.currentMedia?.id }

    /// The glass buttons on the photo.
    var chrome: [UIView] { isViewLoaded ? [play, counter] : [] }
}

/// Other visits as small photos in a row, each with its day and time.
final class VisitStrip: UIScrollView {
    init(visits: [Visit], onTap: @escaping (Visit, UIView) -> Void) {
        super.init(frame: .zero)
        showsHorizontalScrollIndicator = false
        clipsToBounds = false
        translatesAutoresizingMaskIntoConstraints = false
        let row = UIStackView()
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            row.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: frameLayoutGuide.heightAnchor),
            heightAnchor.constraint(equalToConstant: 128),
        ])
        for visit in visits {
            let photo = PhotoView()
            photo.layer.cornerRadius = 12
            photo.layer.cornerCurve = .continuous
            photo.translatesAutoresizingMaskIntoConstraints = false
            photo.show(Yard.store.url(visit.bestPhoto?.small), box: visit.box)
            let when = UILabel(font: Style.footnote, color: Style.soft, lines: 1)
            when.text = "\(Words.recently(visit.at)) \(Words.clock.string(from: visit.at))"
            let cell = UIStackView(arrangedSubviews: [photo, when])
            cell.axis = .vertical
            cell.spacing = 4
            NSLayoutConstraint.activate([photo.widthAnchor.constraint(equalToConstant: 96),
                                         photo.heightAnchor.constraint(equalToConstant: 104)])
            let tap = UITapGestureRecognizer()
            tap.addAction { onTap(visit, photo) }
            cell.addGestureRecognizer(tap)
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = "\(visit.bird?.name ?? "Visit"), \(when.text ?? "")"
            cell.accessibilityTraits = .button
            row.addArrangedSubview(cell)
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}

extension UITapGestureRecognizer {
    /// A tap that runs a closure.
    func addAction(_ action: @escaping () -> Void) {
        let target = ClosureTarget(action)
        addTarget(target, action: #selector(ClosureTarget.run))
        objc_setAssociatedObject(self, &ClosureTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
    }
}

private final class ClosureTarget: NSObject {
    nonisolated(unsafe) static var key = 0
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}
