import UIKit
import YardModel

/// Visits as tiles in a row to swipe through: one way to show a row of
/// visits, on Today and at the top of each journal day. A tile is a visit:
/// tapping it opens the visit on that photo, zooming out of the tile;
/// holding it plays its moment and offers the quick actions.
final class Carousel: UIView, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    enum Size {
        /// Today: big tiles with the time and Claude's caption.
        case big
        /// A journal day: smaller tiles with just the time (the rows below say what).
        case compact

        var width: (CGFloat) -> CGFloat {
            switch self {
            case .big: { min($0 * 0.72, 340) }
            case .compact: { min($0 * 0.4, 180) }
            }
        }

        /// The row's height: a tile's photo (4:5 of its width) and its words, no more.
        var height: CGFloat { self == .big ? 340 : 162 }

        var spacing: CGFloat { self == .big ? 10 : 6 }
    }

    private let visits: [Visit]
    private let size: Size
    private let onTap: (Visit, UIView) -> Void
    private weak var screen: UIViewController?
    private var collectionView: UICollectionView!

    init(visits: [Visit], size: Size = .big, from screen: UIViewController?, onTap: @escaping (Visit, UIView) -> Void) {
        self.visits = visits
        self.size = size
        self.screen = screen
        self.onTap = onTap
        super.init(frame: .zero)
        // The row itself scrolls sideways (not a paging section inside it),
        // so a flick glides past several tiles and comes to rest on one.
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.scrollDirection = .horizontal
        let layout = UICollectionViewCompositionalLayout(sectionProvider: { _, environment in
            // Narrow enough that the next tile shows: it's plainly a row to swipe.
            let width = size.width(environment.container.contentSize.width)
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .absolute(width),
                                                                             heightDimension: .fractionalHeight(1)),
                                                           subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = size.spacing
            section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Style.gutter, bottom: 0, trailing: Style.gutter)
            return section
        }, configuration: configuration)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.register(VisitTile.self, forCellWithReuseIdentifier: "tile")
        collectionView.alwaysBounceVertical = false
        collectionView.alwaysBounceHorizontal = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.decelerationRate = Self.friction
        pin(collectionView)
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { visits.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let tile = collectionView.dequeueReusableCell(withReuseIdentifier: "tile", for: indexPath) as! VisitTile
        tile.show(visits[indexPath.item], size: size)
        return tile
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let urls = indexPaths.compactMap { Yard.store.url(size == .big ? visits[$0.item].bestPhoto?.large : visits[$0.item].bestPhoto?.small) }
        ImageLoader.shared.prefetch(urls, pixels: PhotoView.pixels(for: CGSize(width: size == .big ? 340 : 180, height: size == .big ? 290 : 160)))
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let tile = collectionView.cellForItem(at: indexPath) as? VisitTile else { return }
        onTap(visits[indexPath.item], tile.photo)
    }

    // MARK: - Gliding

    /// Between UIKit's .fast (0.99) and .normal (0.998): a flick carries on
    /// past a few tiles, and slows to a stop soon after.
    private static let friction = UIScrollView.DecelerationRate(rawValue: 0.994)

    /// Where the glide would stop, rounded to the nearest tile's edge. Even a
    /// light flick moves at least one tile.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let step = size.width(scrollView.bounds.width) + size.spacing
        let most = max(scrollView.contentSize.width - scrollView.bounds.width, 0)
        guard step > 0, most > 0 else { return }
        // UIKit's velocity is points per millisecond; this is how far that
        // carries at this friction.
        let rate = Self.friction.rawValue
        let glide = scrollView.contentOffset.x + velocity.x * rate / (1 - rate)
        var tile = (glide / step).rounded()
        let here = (scrollView.contentOffset.x / step).rounded()
        if tile == here, abs(velocity.x) > 0.2 { tile += velocity.x > 0 ? 1 : -1 }
        targetContentOffset.pointee.x = min(max(tile * step, 0), most)
    }

    // MARK: - Holding a tile

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let path = indexPaths.first, let screen else { return nil }
        let visit = visits[path.item]
        return UIContextMenuConfiguration(identifier: path as NSIndexPath,
                                          previewProvider: { MomentPreview(visit: visit) }) { [weak self] _ in
            VisitActions.menu(visit, from: screen) { self?.openTile(at: path) }
        }
    }

    func collectionView(_ collectionView: UICollectionView, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
                        animator: UIContextMenuInteractionCommitAnimating) {
        guard let path = configuration.identifier as? IndexPath else { return }
        animator.addCompletion { [weak self] in self?.openTile(at: path) }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
                        highlightPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        guard let tile = collectionView.cellForItem(at: indexPath) as? VisitTile else { return nil }
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: tile.photo.bounds, cornerRadius: tile.photo.layer.cornerRadius)
        return UITargetedPreview(view: tile.photo, parameters: parameters)
    }

    private func openTile(at path: IndexPath) {
        guard let tile = collectionView.cellForItem(at: path) as? VisitTile else { return }
        onTap(visits[path.item], tile.photo)
    }
}

final class VisitTile: UICollectionViewCell {
    let photo = PhotoView()
    private let time = UILabel(font: Style.footnote, color: Style.soft, lines: 1)
    private let caption = UILabel(font: Style.prose, lines: 3)
    private var photoHeight: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        photo.layer.cornerRadius = 12
        photo.layer.cornerCurve = .continuous
        photo.translatesAutoresizingMaskIntoConstraints = false
        [photo, time, caption].forEach(contentView.addSubview)
        photoHeight = photo.heightAnchor.constraint(equalTo: photo.widthAnchor, multiplier: 0.8)
        NSLayoutConstraint.activate([
            photo.topAnchor.constraint(equalTo: contentView.topAnchor),
            photo.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            photo.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            photoHeight,
            time.topAnchor.constraint(equalTo: photo.bottomAnchor, constant: 8),
            time.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            time.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            caption.topAnchor.constraint(equalTo: time.bottomAnchor, constant: 3),
            caption.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            caption.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ visit: Visit, size: Carousel.Size) {
        let big = size == .big
        photo.layer.cornerRadius = big ? Style.radius : 14
        photo.show(Yard.store.url(big ? visit.bestPhoto?.large : visit.bestPhoto?.small), box: visit.box)
        caption.isHidden = !big
        if big {
            // "Today, 8:30 AM", "Saturday, 10:02 AM"
            time.text = "\(Words.dayName(Yard.calendar.day(of: visit.at))), \(Words.clockWithHalf.string(from: visit.at))"
            let text = visit.caption ?? visit.bird.map { "A **\($0.name)** came." } ?? "Something came to the feeder."
            caption.attributedText = Words.bolded(text, font: Style.prose, lineHeight: 1.1)
        } else {
            // "8:30 · House Finch"
            time.text = "\(Words.clock.string(from: visit.at)) · \(visit.bird?.name ?? "A visitor")"
        }
    }

    override var isHighlighted: Bool {
        didSet { UIView.animate(withDuration: 0.12) { self.alpha = self.isHighlighted ? 0.7 : 1 } }
    }
}
