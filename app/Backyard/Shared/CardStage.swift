import UIKit

/// Where visits open: over everything, as cards that grow out of the photo
/// you tapped and shrink back into it. A card isn't a modal presentation, so
/// nothing ever waits for one to finish: every move is a spring from wherever
/// the card is right then. Grab it while it's still growing, tap it open again
/// while it's shrinking, flick it away mid-flight, as fast as you like.
/// Cards stack: a visit opened from inside a card grows over it.
final class CardStage: UIViewController {
    static private(set) weak var shared: CardStage?
    fileprivate var cards: [Card] = []

    override func loadView() {
        view = Passthrough(stage: self)
        CardStage.shared = self
    }

    /// The card on top, if one is up.
    var top: UIViewController? { cards.last { !$0.leaving }?.content }

    /// Open a card out of `source` (the photo you tapped), which shows `media`.
    func open(_ content: VisitCard, from source: PhotoView?, showing media: String?, animated: Bool = true) {
        // A card on its way back into its photo gives way to the new one.
        if let last = cards.last, last.target == .closed { last.leave() }
        let card = Card(content: content, source: source, media: media, stage: self)
        cards.append(card)
        card.enter(animated: animated)
        parent?.setNeedsStatusBarAppearanceUpdate()
    }

    /// Put away the card `screen` is on.
    func close(containing screen: UIViewController) {
        var at: UIViewController? = screen
        while let here = at {
            if let card = cards.first(where: { $0.content === here }) { card.animate(to: .closed); return }
            at = here.parent
        }
    }

    fileprivate func remove(_ card: Card) {
        guard cards.contains(where: { $0 === card }) else { return }
        card.source?.alpha = 1
        card.content.willMove(toParent: nil)
        card.shell.removeFromSuperview()
        card.dim.removeFromSuperview()
        card.content.removeFromParent()
        cards.removeAll { $0 === card }
        parent?.setNeedsStatusBarAppearanceUpdate()
    }

    /// Touches go to a card only where you can see it; everywhere else they
    /// fall through to the screen underneath (so another photo can be
    /// tapped while one card is still shrinking away).
    private final class Passthrough: UIView {
        weak var stage: CardStage?

        init(stage: CardStage) {
            self.stage = stage
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            for card in (stage?.cards ?? []).reversed() where !card.leaving {
                guard card.visibleFrame.contains(point) else { continue }
                return card.shell.hitTest(card.shell.convert(point, from: self), with: event) ?? card.shell
            }
            return nil
        }
    }

    #if DEBUG
    /// For checking by script, without a finger: the top card's moves.
    var debugTop: (grab: (CGPoint) -> Void, drag: (CGPoint) -> Void, letGo: (CGPoint, CGPoint) -> Void,
                   tap: () -> Void, frame: () -> CGRect)? {
        guard let card = cards.last(where: { !$0.leaving }) else { return nil }
        return ({ card.beginDrag(at: $0) }, { card.drag($0) }, { card.endDrag(velocity: $0, translation: $1) },
                { card.tapped() }, { card.visibleFrame })
    }
    #endif
}

/// Where a card is: scaled and moved as a whole, and cut to a rounded rect
/// within itself. Open, it's the whole screen; closed, its photo sits exactly
/// over the photo it came from, cropped the same way.
private struct Pose {
    var scale: CGFloat
    var offset: CGPoint
    /// The part that shows, in the card's own (unscaled) points.
    var clip: CGRect
    /// Its corners, in screen points.
    var radius: CGFloat
    var dim: CGFloat
}

@MainActor
private final class Card: NSObject, UIGestureRecognizerDelegate {
    enum Target { case open, closed }

    let content: VisitCard
    weak var source: PhotoView?
    /// The photo the source shows; the card shrinks into it only if it's
    /// still showing that one (otherwise it fades as it goes).
    let media: String?
    weak var stage: CardStage?
    /// Scaled and moved as one; its corner at (0, 0), so a pose is just
    /// scale-then-move.
    let shell = UIView()
    let clip = UIView()
    let dim = UIView()
    private(set) var target = Target.closed
    /// Open and done growing: the visit itself takes touches.
    private var settled = false
    private(set) var leaving = false
    /// Every new move bumps it, so an older move's ending doesn't act.
    private var generation = 0
    private let pan = UIPanGestureRecognizer()
    private let tap = UITapGestureRecognizer()
    private var grab: (scale: CGFloat, offset: CGPoint, at: CGPoint, radius: CGFloat, dim: CGFloat)?

    /// Like the corners of the screen, so an open card looks like the screen.
    private static let openRadius: CGFloat = 44

    init(content: VisitCard, source: PhotoView?, media: String?, stage: CardStage) {
        self.content = content
        self.source = source
        self.media = media
        self.stage = stage
        super.init()
        let bounds = stage.view.bounds
        dim.backgroundColor = .black
        dim.alpha = 0
        dim.isUserInteractionEnabled = false
        dim.frame = bounds
        shell.layer.anchorPoint = .zero
        shell.frame = bounds
        clip.backgroundColor = .black
        clip.layer.cornerCurve = .continuous
        clip.frame = bounds
        shell.mask = clip

        pan.addTarget(self, action: #selector(panned))
        pan.delegate = self
        shell.addGestureRecognizer(pan)
        tap.addTarget(self, action: #selector(tapped))
        tap.isEnabled = false
        shell.addGestureRecognizer(tap)
    }

    // MARK: - Poses

    private var openPose: Pose {
        Pose(scale: 1, offset: .zero, clip: shell.bounds, radius: Self.openRadius, dim: 0.3)
    }

    /// Back in its photo, cropped as that photo is; or, with no photo to go
    /// back to, down off the bottom of the screen.
    private func closedPose() -> (pose: Pose, sameMedia: Bool) {
        guard let stage else { return (openPose, true) }
        if let source, source.window != nil, let visit = content.showing, visit.visitID == content.openedVisit,
           let picture = visit.pictureFrame(in: shell, aspect: source.pictureAspect) {
            let tile = source.convert(source.bounds, to: stage.view)
            let tilePicture = source.convert(source.pictureFrame, to: stage.view)
            let s = tilePicture.width / max(picture.width, 1)
            let o = CGPoint(x: tilePicture.minX - s * picture.minX, y: tilePicture.minY - s * picture.minY)
            let clip = CGRect(x: (tile.minX - o.x) / s, y: (tile.minY - o.y) / s,
                              width: tile.width / s, height: tile.height / s)
            return (Pose(scale: s, offset: o, clip: clip, radius: source.layer.cornerRadius, dim: 0),
                    media == nil || visit.photoShowing == media)
        }
        let bounds = stage.view.bounds
        return (Pose(scale: 1, offset: CGPoint(x: 0, y: bounds.height + 20), clip: shell.bounds,
                     radius: Self.openRadius, dim: 0), true)
    }

    private func apply(_ pose: Pose) {
        shell.transform = CGAffineTransform(a: pose.scale, b: 0, c: 0, d: pose.scale, tx: pose.offset.x, ty: pose.offset.y)
        clip.frame = pose.clip
        clip.layer.cornerRadius = pose.radius / pose.scale
        dim.alpha = pose.dim
    }

    /// Where it shows on screen now, mid-flight included.
    var visibleFrame: CGRect {
        let t = shell.layer.presentation()?.affineTransform() ?? shell.transform
        let c = clip.layer.presentation()?.frame ?? clip.frame
        return c.applying(t)
    }

    // MARK: - Moves

    func enter(animated: Bool) {
        guard let stage else { return }
        #if DEBUG
        let began = CACurrentMediaTime()
        defer { print("card: ready to move in \(Int((CACurrentMediaTime() - began) * 1000)) ms") }
        #endif
        content.fullScreenSafeArea = stage.view.safeAreaInsets
        stage.addChild(content)
        stage.view.addSubview(dim)
        stage.view.addSubview(shell)
        content.view.frame = shell.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        shell.addSubview(content.view)
        content.didMove(toParent: stage)
        // Laid out once, at full size, before it moves: it never lays out
        // again while it grows or shrinks, only scales.
        content.view.layoutIfNeeded()
        UIView.performWithoutAnimation {
            apply(closedPose().pose)
            setChrome(0)
        }
        source?.alpha = 0
        if animated {
            animate(to: .open)
        } else {
            target = .open
            apply(openPose)
            setChrome(1)
            settle()
        }
    }

    func animate(to target: Target, velocity: CGPoint = .zero) {
        guard !leaving else { return }
        self.target = target
        generation += 1
        let now = generation
        settled = false
        content.view.isUserInteractionEnabled = false
        tap.isEnabled = target == .closed
        let (pose, sameMedia) = target == .open ? (openPose, true) : closedPose()
        let spring = relativeSpeed(velocity, toward: pose)
        // New moves add onto the ones in flight, so a change of mind keeps
        // the card's momentum instead of jumping.
        UIView.animate(springDuration: target == .open ? 0.5 : 0.42, bounce: target == .open ? 0.12 : 0,
                       initialSpringVelocity: spring, delay: 0, options: [.allowUserInteraction]) {
            self.apply(pose)
        } completion: { [weak self] _ in
            guard let self, now == self.generation, target == .closed else { return }
            self.stage?.remove(self)
        }
        if target == .open {
            source?.alpha = 0
            UIView.animate(withDuration: 0.22, delay: 0.12, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.setChrome(1)
                self.shell.alpha = 1
            }
            // Touches go to the visit once it's nearly there.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, now == self.generation else { return }
                self.settle()
            }
        } else {
            UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.setChrome(0)
            }
            if !sameMedia {
                // On another photo than the one it came from: that one shows
                // again underneath, and the card fades into it.
                source?.alpha = 1
                UIView.animate(withDuration: 0.3, delay: 0.05, options: [.allowUserInteraction, .beginFromCurrentState]) {
                    self.shell.alpha = 0
                }
            }
        }
    }

    private func settle() {
        settled = true
        content.view.isUserInteractionEnabled = true
    }

    /// Another card is opening: this one, already on its way out, fades.
    func leave() {
        leaving = true
        generation += 1
        tap.isEnabled = false
        source?.alpha = 1
        UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState]) {
            self.shell.alpha = 0
            self.dim.alpha = 0
        } completion: { [weak self] _ in
            guard let self else { return }
            self.stage?.remove(self)
        }
    }

    /// The finger's speed as UIKit's spring wants it: a share of the distance
    /// left to go, per second.
    private func relativeSpeed(_ velocity: CGPoint, toward pose: Pose) -> CGFloat {
        guard velocity != .zero else { return 0 }
        let t = shell.transform
        let here = CGPoint(x: t.tx + t.a * clip.frame.midX, y: t.ty + t.a * clip.frame.midY)
        let there = CGPoint(x: pose.offset.x + pose.scale * pose.clip.midX, y: pose.offset.y + pose.scale * pose.clip.midY)
        let d = CGPoint(x: there.x - here.x, y: there.y - here.y)
        let distance = hypot(d.x, d.y)
        guard distance > 1 else { return 0 }
        let along = (velocity.x * d.x + velocity.y * d.y) / distance
        return min(max(along / distance, -8), 40)
    }

    /// Stop everything where it is on screen right now, to be moved by hand.
    private func freeze() {
        if let p = shell.layer.presentation() {
            shell.transform = p.affineTransform()
            shell.alpha = CGFloat(p.opacity)
        }
        if let p = clip.layer.presentation() {
            clip.frame = p.frame
            clip.layer.cornerRadius = p.cornerRadius
        }
        if let p = dim.layer.presentation() { dim.alpha = CGFloat(p.opacity) }
        for view in content.chrome {
            if let p = view.layer.presentation() { view.alpha = CGFloat(p.opacity) }
            view.layer.removeAllAnimations()
        }
        [shell.layer, clip.layer, dim.layer].forEach { $0.removeAllAnimations() }
    }

    private func setChrome(_ alpha: CGFloat) {
        content.chrome.forEach { $0.alpha = alpha }
    }

    // MARK: - Touch

    @objc func tapped() {
        animate(to: .open)
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard let view = stage?.view else { return }
        switch pan.state {
        case .began: beginDrag(at: pan.location(in: view))
        case .changed: drag(pan.translation(in: view))
        case .ended, .cancelled, .failed: endDrag(velocity: pan.velocity(in: view), translation: pan.translation(in: view))
        default: break
        }
    }

    func beginDrag(at point: CGPoint) {
        freeze()
        generation += 1
        settled = false
        content.view.isUserInteractionEnabled = false
        tap.isEnabled = false
        let t = shell.transform
        grab = (t.a, CGPoint(x: t.tx, y: t.ty), point, clip.layer.cornerRadius * t.a, dim.alpha)
    }

    /// The card follows the finger, shrinking as it goes down, around the
    /// point you're holding so that point stays under your finger.
    func drag(_ translation: CGPoint) {
        guard let grab, let bounds = stage?.view.bounds else { return }
        var down = translation.y
        if down < 0 && grab.scale > 0.98 { down *= 0.3 }  // already as big as it gets
        let shrink = 1 - 0.5 * min(max(down, 0) / bounds.height, 1)
        let s = grab.scale * shrink
        shell.transform = CGAffineTransform(a: s, b: 0, c: 0, d: s,
                                            tx: grab.at.x + shrink * (grab.offset.x - grab.at.x) + translation.x,
                                            ty: grab.at.y + shrink * (grab.offset.y - grab.at.y) + down)
        clip.layer.cornerRadius = max(grab.radius, 12) / s
        dim.alpha = grab.dim * (1 - min(max(down, 0) / (bounds.height * 0.5), 1))
    }

    /// Let go: a flick down, or far enough down, puts it away; anything else
    /// opens it (catching a card on its way out brings it back).
    func endDrag(velocity: CGPoint, translation: CGPoint) {
        guard grab != nil else { return }
        grab = nil
        let away = velocity.y > 300 || (translation.y > 110 && velocity.y > -300)
        animate(to: away ? .closed : .open, velocity: velocity)
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard !leaving else { return false }
        guard gesture === pan else { return true }
        if target == .closed { return true }
        let v = pan.velocity(in: shell)
        let vertical = abs(v.y) > abs(v.x)
        // Still growing: any up-or-down drag catches it.
        guard settled else { return vertical }
        // Open: down, from the top of the visit.
        return vertical && v.y > 0 && content.atTop
    }

    /// The visit's own drags (scrolling, swiping photos and visits) wait to
    /// see that this isn't a drag of the card.
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        gesture === pan && other is UIPanGestureRecognizer && other.view?.isDescendant(of: content.view) == true
    }
}
