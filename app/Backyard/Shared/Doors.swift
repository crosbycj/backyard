import AVFoundation
import SafariServices
import UIKit
import YardModel
import YardStore

/// Every noun is a door. A bird's name opens the bird, a photo opens its
/// visit, a day opens the journal there, and a link opens the web, the same
/// way from every screen. A push asked for twice in a row (a double tap, a
/// tap mid-transition) happens once; a visit opens at any moment.
extension UIViewController {
    private var canGo: Bool {
        presentedViewController == nil
            && (navigationController?.transitionCoordinator == nil)
    }

    /// A visit, swiping on to the ones before and after it among `visits`
    /// (the list it was opened from), as a card that grows out of the photo
    /// you tapped and goes back into it (CardStage). Never refused for being
    /// in the middle of something: the stage takes cards at any moment.
    func open(visit: Visit, among visits: [Visit]? = nil, at media: String? = nil, from source: UIView? = nil) {
        guard visit.source != .report, presentedViewController == nil, let stage = CardStage.shared else { return }
        let list = (visits ?? [visit]).filter { $0.source != .report }
        let card = VisitCard(visits: list.contains(where: { $0.id == visit.id }) ? list : [visit],
                             start: visit.id, at: media)
        stage.open(card, from: source as? PhotoView, showing: media ?? visit.bestPhoto?.id)
    }

    /// Put away the card this screen is on.
    func closeCard() {
        CardStage.shared?.close(containing: self)
    }

    /// A bird: what it is, and the journal narrowed to it.
    func open(bird key: String?) {
        guard let key, canGo, let nav = navigationController, let bird = try? Yard.store.bird(key) else { return }
        if let top = nav.topViewController as? JournalViewController, top.lens.bird == key { return }
        nav.pushViewController(JournalViewController(lens: Lens(bird: key), title: bird.name), animated: true)
    }

    /// The journal, at a day, on top of where you are, so a swipe back
    /// returns there. (In the journal itself, it just scrolls.)
    func openJournal(at day: String) {
        if let journal = self as? JournalViewController, journal.lens == .journal {
            journal.scroll(to: day)
            return
        }
        guard canGo, let nav = navigationController else { return }
        let journal = JournalViewController(lens: .journal, title: "Journal")
        journal.navigationItem.largeTitleDisplayMode = .never
        journal.scroll(to: day)
        nav.pushViewController(journal, animated: true)
    }

    /// A page on the web, inside the app.
    func open(link: URL?) {
        guard let link else { return }
        let safari = SFSafariViewController(url: link)
        safari.preferredControlTintColor = Style.accent
        present(safari, animated: true)
    }

    /// "Tell me more about this visit" and a link to its page, on the
    /// clipboard, ready to paste to Claude, who reads the page and its photos.
    func askClaude(_ ask: String, page: String?) {
        let link = Yard.store.url(page)?.absoluteString
        UIPasteboard.general.string = [ask, link].compactMap { $0 }.joined(separator: "\n")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        toast("Copied. Paste it to Claude.")
    }

    /// A short word at the bottom of the screen.
    func toast(_ text: String) {
        let label = PaddedLabel(text: text)
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
        label.alpha = 0
        UIView.animate(withDuration: 0.2) { label.alpha = 1 }
        UIView.animate(withDuration: 0.3, delay: 1.6) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
    }
}

enum Links {
    /// Its Wikipedia article, by its scientific name (which redirects to the species).
    static func wikipedia(_ bird: Bird) -> URL? {
        let title = (bird.scientific ?? bird.name).replacingOccurrences(of: " ", with: "_")
        return URL(string: "https://en.wikipedia.org/wiki/" + (title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title))
    }
}

/// A row you can tap: a symbol, its name, a line under it, and a chevron.
/// The one look for a door in a list; rows sit together in a Panel.
final class DoorRow: UIControl, Inset {
    private let title = UILabel(font: Style.headline)
    private let detail = UILabel(font: Style.subheadline, color: Style.soft)
    private let icon = UIImageView()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let action: () -> Void
    /// Where its words start, for the hairline above it.
    let textInset: CGFloat

    init(_ title: String, detail: String? = nil, symbol: String? = nil, leading: UIView? = nil,
         attributed: NSAttributedString? = nil, chevron showsChevron: Bool = true, action: @escaping () -> Void) {
        self.action = action
        textInset = leading.map { $0.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width + 12 }
            ?? (symbol == nil ? 0 : 28 + 12)
        super.init(frame: .zero)
        let lead: UIView? = leading ?? (symbol == nil ? nil : icon)
        translatesAutoresizingMaskIntoConstraints = false
        self.title.text = title
        if let attributed { self.title.attributedText = attributed }
        self.title.numberOfLines = 2
        self.detail.text = detail
        self.detail.isHidden = detail == nil
        // Never cut short: a row says all it has to say.
        self.detail.numberOfLines = 0
        icon.image = symbol.flatMap { UIImage(systemName: $0) }
        icon.tintColor = Style.accent
        icon.contentMode = .center
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        chevron.tintColor = Style.soft.withAlphaComponent(0.6)
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .default)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        chevron.isHidden = !showsChevron
        let words = UIStackView(arrangedSubviews: [self.title, self.detail])
        words.axis = .vertical
        words.spacing = 2
        let row = UIStackView(arrangedSubviews: (lead.map { [$0] } ?? []) + [words, chevron])
        row.alignment = .center
        row.spacing = 12
        row.isUserInteractionEnabled = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        pin(row, insets: UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0))
        heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        // A plain control never sends .primaryActionTriggered (only buttons do).
        addAction(UIAction { [weak self] _ in self?.action() }, for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityLabel = [attributed?.string ?? title, detail].compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { UIView.animate(withDuration: 0.12) { self.alpha = self.isHighlighted ? 0.45 : 1 } }
    }
}

/// A rounded button. Filled is the screen's one loud action ("Play the
/// day"); the rest are tinted, quieter.
final class Pill: UIButton {
    init(_ title: String, symbol: String, filled: Bool = false, action: @escaping () -> Void) {
        super.init(frame: .zero)
        var config = filled ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        config.title = title
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote)
            .applying(UIImage.SymbolConfiguration(weight: .semibold)))
        config.imagePadding = 6
        config.cornerStyle = .capsule
        config.baseForegroundColor = filled ? Style.card : Style.accent
        config.baseBackgroundColor = filled ? Style.accent : Style.fill
        config.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var a = attributes
            a.font = Style.weight(Style.subheadline, .semibold)
            return a
        }
        configuration = config
        addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Pills (or any small views) in a row that wraps onto more lines when
/// they don't fit, each line's items centered on one another.
final class PillRow: UIView {
    private let pills: [UIView]
    private let spacing: CGFloat
    private let lineSpacing: CGFloat

    init(_ pills: [UIView], spacing: CGFloat = 8, lineSpacing: CGFloat = 8) {
        self.pills = pills
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        pills.forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func place(width: CGFloat) -> CGFloat {
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        var lineItems: [(UIView, CGSize)] = []
        func finishLine() {
            for (view, size) in lineItems { view.frame.origin.y = y + (line - size.height) / 2 }
            lineItems = []
        }
        for pill in pills {
            let size = pill.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            if x > 0 && x + size.width > width { finishLine(); x = 0; y += line + lineSpacing; line = 0 }
            pill.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            lineItems.append((pill, size))
            x += size.width + spacing
            line = max(line, size.height)
        }
        finishLine()
        return y + line
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = place(width: bounds.width)
        if height != lastHeight { lastHeight = height; invalidateIntrinsicContentSize() }
    }

    private var lastHeight: CGFloat = 0

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: lastHeight > 0 ? lastHeight : place(width: bounds.width > 0 ? bounds.width : 360))
    }
}

final class PaddedLabel: UILabel {
    init(text: String) {
        super.init(frame: .zero)
        self.text = text
        font = Style.weight(Style.subheadline, .semibold)
        textColor = Style.paper
        backgroundColor = Style.ink
        textAlignment = .center
        layer.cornerRadius = 17
        layer.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 32, height: max(size.height + 14, 34))
    }
}

/// One bird call playing at a time, from any screen.
@MainActor
final class CallPlayer {
    static let shared = CallPlayer()
    /// Posted when a call starts or stops, so every button shows the truth.
    static let changed = Notification.Name("CallPlayerChanged")
    private var player: AVPlayer?
    private(set) var playing: URL?
    private var ended: NSObjectProtocol?

    /// Play it, or stop it if it's the one playing.
    func toggle(_ url: URL) {
        if playing == url { stop(); return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        playing = url
        ended.map(NotificationCenter.default.removeObserver)
        ended = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                       object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        player?.play()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func stop() {
        player?.pause()
        player = nil
        playing = nil
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}

/// What you can do with a bird, as tiles: hear its call, read about it,
/// ask Claude.
@MainActor
func birdActions(_ bird: Bird, from screen: UIViewController) -> ActionTiles {
    var actions: [ActionTiles.Action] = []
    if let call = bird.call {
        let playing = CallPlayer.shared.playing == call.url
        actions.append(.init(title: playing ? "Stop" : "Its call", symbol: playing ? "stop.fill" : "waveform") {
            CallPlayer.shared.toggle(call.url)
        })
    }
    actions.append(.init(title: "Field guide", symbol: "book.closed") { [weak screen] in screen?.open(link: bird.guide) })
    actions.append(.init(title: "Wikipedia", symbol: "globe") { [weak screen] in screen?.open(link: Links.wikipedia(bird)) })
    actions.append(.init(title: "Ask Claude", symbol: "sparkle") { [weak screen] in
        screen?.askClaude("Tell me about the \(bird.name)s that visit my yard.", page: bird.page)
    })
    return ActionTiles(actions)
}
