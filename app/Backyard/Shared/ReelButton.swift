import AVKit
import UIKit
import YardModel

/// "▶ Today in 35 seconds": a day's reel (each visit's best few seconds),
/// played fullscreen out of the button, already playing.
final class ReelButton: UIView {
    private let reel: Reel
    private weak var screen: UIViewController?
    private var pill: Pill!

    init(_ reel: Reel, title: String, from screen: UIViewController) {
        self.reel = reel
        self.screen = screen
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        pill = Pill(title, symbol: "play.fill", filled: true) { [weak self] in self?.play() }
        // The button on its own, at its own width.
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)
        NSLayoutConstraint.activate([
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),
            pill.leadingAnchor.constraint(equalTo: leadingAnchor),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func play() {
        guard let screen else { return }
        Self.play(reel, from: screen, out: pill)
    }

    /// The reel fullscreen, growing out of what was tapped.
    @MainActor
    static func play(_ reel: Reel, from screen: UIViewController, out of: UIView?) {
        guard let url = Yard.store.url(reel.video) else { return }
        let fullscreen = VideoScreen(player: AVPlayer(url: url), still: nil, start: 0)
        fullscreen.zoom { [weak of] in of }
        screen.present(fullscreen, animated: true)
    }
}
