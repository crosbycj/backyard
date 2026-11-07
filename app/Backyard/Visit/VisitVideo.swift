import AVKit
import UIKit
import YardModel

/// A visit's minute of video, ready before it's asked for. The photos are
/// moments in it, so the same player plays it fullscreen from a photo's
/// instant, and plays a photo's few seconds while you hold it.
@MainActor
final class VisitVideo {
    let player = AVPlayer()
    private let remote: URL
    private var prepared = false

    init?(_ visit: Visit) {
        guard let path = visit.video?.video, let url = Yard.store.url(path) else { return nil }
        remote = url
        player.actionAtItemEnd = .pause
    }

    /// Get it ready: streamed at once, and on Wi-Fi the whole file fetched
    /// onto the phone so jumping to a photo's instant is quick. Asking twice does nothing.
    func prepare() {
        guard !prepared else { return }
        prepared = true
        let item = AVPlayerItem(url: remote)
        item.preferredForwardBufferDuration = 4
        player.replaceCurrentItem(with: item)
        if !Yard.onCellular { fetch() }
    }

    /// The whole file onto the phone, then play from it.
    func fetch() {
        Task {
            guard let file = await ImageLoader.shared.localFile(remote), player.rate == 0 else { return }
            let at = player.currentTime()
            player.replaceCurrentItem(with: AVPlayerItem(url: file))
            await player.seek(to: at, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }
}

/// The video's frames in the photo's place, while you hold a photo (and
/// fullscreen, over the photo it grew out of).
final class FrameView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    init(player: AVPlayer) {
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        backgroundColor = .black
        isUserInteractionEnabled = false
        alpha = 0
    }

    required init?(coder: NSCoder) { fatalError() }
}
