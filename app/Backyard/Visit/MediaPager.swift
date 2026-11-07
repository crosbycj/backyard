import UIKit
import YardModel

/// A visit's photos side by side: swipe between them, pinch or double-tap
/// to look closer. The video's page shows the best photo with a play button.
///
/// The pages stay full size when the Visit collapses the pager: the pager
/// clips them around their middle, so shrinking it costs no layout.
final class MediaPager: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var onPage: ((Int) -> Void)?
    var onPlay: ((Media) -> Void)?
    private let pages: [Media]
    private let poster: Media?
    private var collectionView: UICollectionView!
    private var pendingPage: Int?
    private(set) var current = 0
    /// The pages' height; the pager itself may be shorter (collapsed).
    var pageHeight: CGFloat = 0 { didSet { if pageHeight != oldValue { view.setNeedsLayout() } } }

    init(pages: [Media], poster: Media?) {
        self.pages = pages
        self.poster = poster
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        view.backgroundColor = .black
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        collectionView = PhotoStrip(frame: view.bounds, collectionViewLayout: layout)
        collectionView.isPagingEnabled = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.backgroundColor = .black
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(PageCell.self, forCellWithReuseIdentifier: "page")
        view.addSubview(collectionView)
    }

    func scroll(to page: Int) { pendingPage = page }

    /// Jump straight to a photo (after scrubbing or watching), without a swipe.
    func show(page: Int) {
        guard pages.indices.contains(page), collectionView.bounds.width > 0 else { pendingPage = page; return }
        current = page
        collectionView.contentOffset.x = CGFloat(page) * collectionView.bounds.width
        prefetch(around: page)
    }

    /// The photo on the current page, if it's loaded: for sharing and saving.
    var currentImage: UIImage? {
        (collectionView.cellForItem(at: IndexPath(item: current, section: 0)) as? PageCell)?.image
    }

    var currentMedia: Media? { pages.indices.contains(current) ? pages[current] : nil }

    /// Where the current photo is drawn, uncropped, in `other`'s points. Before
    /// it has loaded, as a photo of `aspect` (width over height) would be.
    func pictureFrame(in other: UIView, aspect: CGFloat) -> CGRect? {
        (collectionView.cellForItem(at: IndexPath(item: current, section: 0)) as? PageCell)?
            .pictureFrame(in: other, aspect: aspect)
    }

    private var laidOut: CGSize = .zero

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let height = max(pageHeight, view.bounds.height)
        // Centered in the pager, so a collapsed pager shows the middle of each photo.
        collectionView.frame = CGRect(x: 0, y: (view.bounds.height - height) / 2,
                                      width: view.bounds.width, height: height)
        let size = collectionView.bounds.size
        guard size != laidOut, size.width > 0 else { return }
        laidOut = size
        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.layoutIfNeeded()
        let page = pendingPage ?? current
        if pages.indices.contains(page) {
            collectionView.contentOffset.x = CGFloat(page) * size.width
            current = page
            prefetch(around: page)
        }
        pendingPage = nil
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { pages.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "page", for: indexPath) as! PageCell
        let media = pages[indexPath.item]
        if media.kind == .video {
            cell.show(Yard.store.url(poster?.large), video: true, pixels: pixels)
            cell.onPlay = { [weak self] in self?.onPlay?(media) }
        } else {
            cell.show(Yard.store.url(media.large), video: false, pixels: pixels)
        }
        return cell
    }

    private var pixels: CGFloat {
        max(collectionView.bounds.width, collectionView.bounds.height, 300) * UIScreen.main.scale
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        collectionView.bounds.size
    }

    /// The counter follows the finger, not the end of the swipe.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.bounds.width > 0, !pages.isEmpty else { return }
        let page = min(max(Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded()), 0), pages.count - 1)
        guard page != current else { return }
        current = page
        onPage?(page)
        prefetch(around: page)
    }

    private func prefetch(around page: Int) {
        let near = [page - 1, page + 1, page + 2].filter(pages.indices.contains)
        let urls = near.compactMap { i in Yard.store.url(pages[i].kind == .video ? poster?.large : pages[i].large) }
        ImageLoader.shared.prefetch(urls, pixels: pixels)
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        (cell as? PageCell)?.resetZoom()
    }
}

/// The photos' strip. A drag that starts at the screen's edge, or pushes
/// past the first or last photo, isn't the photos': the strip lets it go,
/// and the card under it turns to the visit before or after, following the
/// finger the whole way.
final class PhotoStrip: UICollectionView {
    private static let edge: CGFloat = 28

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === panGestureRecognizer, bounds.width > 0 else { return super.gestureRecognizerShouldBegin(gesture) }
        let velocity = panGestureRecognizer.velocity(in: self)
        guard abs(velocity.x) > abs(velocity.y) else { return super.gestureRecognizerShouldBegin(gesture) }
        if let window {
            let x = panGestureRecognizer.location(in: window).x
            if x < Self.edge || x > window.bounds.width - Self.edge { return false }
        }
        let page = Int((contentOffset.x / bounds.width).rounded())
        let last = numberOfItems(inSection: 0) - 1
        if velocity.x > 0 && page <= 0 { return false }     // before the first photo: the visit before
        if velocity.x < 0 && page >= last { return false }  // past the last: the visit after
        return super.gestureRecognizerShouldBegin(gesture)
    }
}

/// One page: a photo that zooms, or the video's poster and play button.
final class PageCell: UICollectionViewCell, UIScrollViewDelegate {
    var onPlay: (() -> Void)?
    private let zoom = UIScrollView()
    private let imageView = UIImageView()
    private let play = UIButton(type: .system)
    private var task: Task<Void, Never>?
    private var url: URL?

    var image: UIImage? { imageView.image }

    override init(frame: CGRect) {
        super.init(frame: frame)
        zoom.delegate = self
        zoom.minimumZoomScale = 1
        zoom.maximumZoomScale = 4
        zoom.showsVerticalScrollIndicator = false
        zoom.showsHorizontalScrollIndicator = false
        zoom.contentInsetAdjustmentBehavior = .never
        zoom.frame = contentView.bounds
        zoom.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(zoom)
        // Fill the page: it's a little shorter than a 3:4 photo, so this trims
        // the top and bottom instead of leaving bars at the sides.
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        zoom.addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom))
        doubleTap.numberOfTapsRequired = 2
        zoom.addGestureRecognizer(doubleTap)

        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "play.circle.fill",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 64))
        config.baseForegroundColor = .white
        play.configuration = config
        play.layer.shadowOpacity = 0.4
        play.layer.shadowRadius = 8
        play.layer.shadowOffset = .zero
        play.accessibilityLabel = "Play the video"
        play.addAction(UIAction { [weak self] _ in self?.onPlay?() }, for: .primaryActionTriggered)
        play.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(play)
        NSLayoutConstraint.activate([
            play.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            play.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ url: URL?, video: Bool, pixels: CGFloat) {
        play.isHidden = !video
        zoom.isUserInteractionEnabled = !video
        imageView.alpha = video ? 0.75 : 1
        task?.cancel()
        task = nil
        self.url = url
        guard let url else { imageView.image = nil; return }
        // Something to see at once: any size we have, then the sharp one.
        imageView.image = ImageLoader.shared.anyCached(url)
        guard ImageLoader.shared.cached(url, pixels: pixels) == nil else {
            imageView.image = ImageLoader.shared.cached(url, pixels: pixels)
            return
        }
        task = Task { [weak self] in
            let loaded = await ImageLoader.shared.image(url, pixels: pixels)
            // A reused cell may be showing another photo by now.
            guard let self, !Task.isCancelled, self.url == url, let loaded else { return }
            self.imageView.image = loaded
        }
    }

    func resetZoom() { zoom.setZoomScale(1, animated: false) }

    func pictureFrame(in other: UIView, aspect: CGFloat) -> CGRect {
        let size = imageView.image?.size ?? CGSize(width: aspect, height: 1)
        let b = imageView.bounds
        let s = max(b.width / max(size.width, 1e-3), b.height / max(size.height, 1e-3))
        let w = size.width * s, h = size.height * s
        return imageView.convert(CGRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h), to: other)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        zoom.frame = contentView.bounds
        if zoom.zoomScale == 1 { imageView.frame = zoom.bounds }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        resetZoom()
        onPlay = nil
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func toggleZoom(_ tap: UITapGestureRecognizer) {
        if zoom.zoomScale > 1 {
            zoom.setZoomScale(1, animated: true)
        } else {
            let point = tap.location(in: imageView)
            let size = CGSize(width: zoom.bounds.width / 2.5, height: zoom.bounds.height / 2.5)
            zoom.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                 width: size.width, height: size.height), animated: true)
        }
    }
}
