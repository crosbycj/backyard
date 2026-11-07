import AVKit
import Photos
import UIKit
import YardModel

/// What you can do with a visit from anywhere: from its page's ⋯ menu, or
/// by holding its photo in a carousel. One set of actions, the same words.
@MainActor
enum VisitActions {
    /// The quick actions for holding a visit's photo: open it, save its
    /// photo, ask Claude about it, share it.
    static func menu(_ visit: Visit, from screen: UIViewController, open: @escaping () -> Void) -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Open", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { _ in open() },
            UIAction(title: "Save photo to Photos", image: UIImage(systemName: "photo.badge.arrow.down")) { [weak screen] _ in
                guard let screen else { return }
                save(visit, photo: visit.bestPhoto, video: false, from: screen)
            },
            UIAction(title: "Ask Claude about this visit", image: UIImage(systemName: "sparkle")) { [weak screen] _ in
                screen?.askClaude("Tell me more about this visit.", page: visit.page)
            },
            UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { [weak screen] _ in
                guard let screen else { return }
                share(visit, image: Yard.store.url(visit.bestPhoto?.large).flatMap(ImageLoader.shared.anyCached), from: screen)
            },
        ])
    }

    /// A photo (full size) or the visit's video into Photos, dated when
    /// the bird came. Asks only to add, never to read the library.
    static func save(_ visit: Visit, photo: Media?, video: Bool, from screen: UIViewController) {
        guard let url = video ? Yard.store.url(visit.video?.video) : Yard.store.url((photo ?? visit.bestPhoto)?.large) else { return }
        let when = visit.at
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                screen.toast("Allow Backyard to add to Photos in Settings.")
                return
            }
            if video { screen.toast("Saving the video…") }
            guard let file = await ImageLoader.shared.localFile(url) else {
                screen.toast("Couldn't download it. Try again.")
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.creationDate = when
                    request.addResource(with: video ? .video : .photo, fileURL: file, options: nil)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                screen.toast(video ? "Video saved to Photos" : "Photo saved to Photos")
            } catch {
                screen.toast("Couldn't save it to Photos.")
            }
        }
    }

    /// The photo, the caption and the visit's page, to Messages or anywhere.
    static func share(_ visit: Visit, image: UIImage?, from screen: UIViewController) {
        var items: [Any] = []
        if let image { items.append(image) }
        items.append(Words.plain(visit.caption ?? visit.bird?.name ?? "A visit to the feeder"))
        if let page = Yard.store.url(visit.page) { items.append(page) }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = screen.view
        screen.present(sheet, animated: true)
    }
}

/// What holding a visit's photo shows: its moment, playing silently over
/// and over (from the photo's time in its video), over the photo itself.
final class MomentPreview: UIViewController {
    private let visit: Visit
    private let photo = PhotoView()
    private var player: AVPlayer?
    private var loop: Any?

    init(visit: Visit) {
        self.visit = visit
        super.init(nibName: nil, bundle: nil)
        let aspect = visit.bestPhoto?.aspect ?? 0.75
        preferredContentSize = CGSize(width: 340, height: 340 / aspect)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.pin(photo)
        photo.show(Yard.store.url(visit.bestPhoto?.large), box: nil)
        guard let path = visit.video?.video, let url = Yard.store.url(path),
              let best = visit.bestPhoto, let moment = visit.moment(of: best) else { return }
        let player = AVPlayer(url: url)
        player.isMuted = true
        self.player = player
        let frames = FrameView(player: player)
        view.pin(frames)
        let from = CMTime(seconds: max(0, moment - 1), preferredTimescale: 600)
        player.seek(to: from, toleranceBefore: .zero, toleranceAfter: .zero) { [weak frames] _ in
            Task { @MainActor in
                player.play()
                UIView.animate(withDuration: 0.2) { frames?.alpha = 1 }
            }
        }
        loop = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: moment + 2, preferredTimescale: 600))],
                                              queue: .main) {
            player.seek(to: from, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let loop { player?.removeTimeObserver(loop) }
        player?.pause()
    }
}
