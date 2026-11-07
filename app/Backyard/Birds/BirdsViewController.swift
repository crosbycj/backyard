import UIKit
import YardModel
import YardStore

/// Every bird that's come, as a grid of faces: each cropped close from its
/// best clear photo (Claude's box around it), so they don't all look like
/// the red feeder. The yard list first. Under them, the birds likely this
/// month that haven't come yet, as empty circles: the yard list is a
/// collection to fill in. A bird opens its page; a likely one, what to
/// look for.
final class BirdsViewController: UIViewController, UICollectionViewDelegate {
    /// How the list is ordered; remembered between launches.
    enum Order: String, CaseIterable {
        case yardList, visits, recent, name

        var title: String {
            switch self {
            case .yardList: "Yard list"
            case .visits: "Most visits"
            case .recent: "Recently seen"
            case .name: "A to Z"
            }
        }

        var symbol: String {
            switch self {
            case .yardList: "list.number"
            case .visits: "chart.bar"
            case .recent: "clock"
            case .name: "textformat"
            }
        }

        func sorted(_ birds: [Bird]) -> [Bird] {
            switch self {
            case .yardList: birds  // the store's order
            case .visits: birds.sorted { ($0.photographed, $0.lastSeen) > ($1.photographed, $1.lastSeen) }
            case .recent: birds.sorted { $0.lastSeen > $1.lastSeen }
            case .name: birds.sorted { $0.name < $1.name }
            }
        }
    }

    private var order = Order(rawValue: UserDefaults.standard.string(forKey: "birds.order") ?? "") ?? .yardList {
        didSet {
            UserDefaults.standard.set(order.rawValue, forKey: "birds.order")
            updateSortMenu()
            reload()
        }
    }

    private var birds: [Bird] = []
    private var likely: [Likely.Hope] = []
    private var likelyMonth: String?
    /// Seen birds are their keys; likely ones are "likely:" and a name.
    private static let hope = "likely:"
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Birds"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Style.page
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: Self.layout())
        collectionView.backgroundColor = Style.page
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        view.addSubview(collectionView)

        let cell = UICollectionView.CellRegistration<BirdCell, String> { [weak self] cell, _, key in
            if let bird = self?.birds.first(where: { $0.key == key }) { cell.show(bird) }
        }
        let hope = UICollectionView.CellRegistration<LikelyCell, String> { [weak self] cell, _, id in
            if let bird = self?.likely.first(where: { Self.hope + $0.name == id }) { cell.show(bird) }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, path, id in
            id.hasPrefix(Self.hope) ? view.dequeueConfiguredReusableCell(using: hope, for: path, item: id)
                : view.dequeueConfiguredReusableCell(using: cell, for: path, item: id)
        }
        let header = UICollectionView.SupplementaryRegistration<LikelyHeader>(
            elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, _ in
            view.show(month: self?.likelyMonth)
        }
        dataSource.supplementaryViewProvider = { view, _, path in
            view.dequeueConfiguredReusableSupplementary(using: header, for: path)
        }
        NotificationCenter.default.addObserver(forName: YardStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        updateSortMenu()
        reload()
    }

    private func updateSortMenu() {
        let menu = UIMenu(title: "Sort by", options: .singleSelection, children: Order.allCases.map { order in
            UIAction(title: order.title, image: UIImage(systemName: order.symbol),
                     state: order == self.order ? .on : .off) { [weak self] _ in self?.order = order }
        })
        let button = UIBarButtonItem(image: UIImage(systemName: "arrow.up.arrow.down"), menu: menu)
        button.accessibilityLabel = "Sort by \(order.title)"
        navigationItem.rightBarButtonItem = button
    }

    /// Three across, or two at the largest text sizes.
    private static func layout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { index, environment in
            let across = environment.traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 2 : 3
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1 / CGFloat(across)),
                                                                heightDimension: .estimated(170)))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                                             heightDimension: .estimated(170)),
                                                           repeatingSubitem: item, count: across)
            group.interItemSpacing = .fixed(8)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 20
            section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: Style.gutter, bottom: 32, trailing: Style.gutter)
            if index == 1 {
                section.boundarySupplementaryItems = [NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(60)),
                    elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)]
            }
            return section
        }
    }

    private func reload() {
        birds = order.sorted((try? Yard.store.birds()) ?? [])
        // The likely ones that still haven't come (the list may be older than a visit).
        let season = try? Yard.store.likely()
        let names = Set(birds.map(\.name))
        likely = (season?.birds ?? []).filter { !names.contains($0.name) }
        likelyMonth = season?.month
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(birds.map(\.key), toSection: 0)
        if !likely.isEmpty {
            snapshot.appendSections([1])
            snapshot.appendItems(likely.map { Self.hope + $0.name }, toSection: 1)
        }
        let shown = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { shown.indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        if let hope = likely.first(where: { Self.hope + $0.name == id }) {
            let sheet = UINavigationController(rootViewController: LikelyViewController(hope))
            sheet.sheetPresentationController?.detents = [.medium()]
            sheet.sheetPresentationController?.prefersGrabberVisible = true
            present(sheet, animated: true)
        } else {
            open(bird: id)
        }
    }
}

/// A bird's face, its name, and how often it's come. A bird Claude isn't
/// sure of yet is dimmed, off the yard list.
final class BirdCell: UICollectionViewCell {
    private let face = FaceView(size: 96)
    private let name = UILabel(font: Style.weight(Style.subheadline, .semibold), lines: 2)
    private let line = UILabel(font: Style.footnote, color: Style.soft, lines: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        name.textAlignment = .center
        name.adjustsFontSizeToFitWidth = true
        name.minimumScaleFactor = 0.8
        line.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [face, name, line])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 2
        stack.setCustomSpacing(8, after: face)
        contentView.pin(stack)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ bird: Bird) {
        face.show(bird: bird.key)
        name.text = bird.name
        let sure = bird.yardNo != nil
        line.text = sure ? Words.count(bird.photographed, "visit") : "Not yet sure"
        face.alpha = sure ? 1 : 0.55
        accessibilityLabel = "\(bird.name), \(line.text ?? ""), last seen \(Words.recently(bird.lastSeen))"
    }

    override var isHighlighted: Bool {
        didSet { UIView.animate(withDuration: 0.12) { self.contentView.alpha = self.isHighlighted ? 0.5 : 1 } }
    }
}

/// A bird likely this month that hasn't come yet: an empty circle where
/// its face will be, its name, and how likely.
final class LikelyCell: UICollectionViewCell {
    private let ring = DashedRing(size: 96)
    private let name = UILabel(font: Style.weight(Style.subheadline, .semibold), color: Style.soft, lines: 2)
    private let line = UILabel(font: Style.footnote, color: Style.soft, lines: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        name.textAlignment = .center
        name.adjustsFontSizeToFitWidth = true
        name.minimumScaleFactor = 0.8
        line.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [ring, name, line])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 2
        stack.setCustomSpacing(8, after: ring)
        contentView.pin(stack)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ bird: Likely.Hope) {
        name.text = bird.name
        line.text = bird.chance.capitalizedFirst
        accessibilityLabel = "\(bird.name), not seen yet, \(bird.chance) this month"
    }

    override var isHighlighted: Bool {
        didSet { UIView.animate(withDuration: 0.12) { self.contentView.alpha = self.isHighlighted ? 0.5 : 1 } }
    }
}

/// A dashed circle with a bird in it: a place kept for one that hasn't come.
final class DashedRing: UIView {
    private let ring = CAShapeLayer()

    init(size: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size)])
        ring.fillColor = nil
        ring.lineWidth = 1.5
        ring.lineDashPattern = [5, 4]
        layer.addSublayer(ring)
        let bird = UIImageView(image: UIImage(systemName: "bird"))
        bird.tintColor = Style.soft.withAlphaComponent(0.6)
        bird.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: size * 0.3)
        bird.contentMode = .center
        pin(bird)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        ring.frame = bounds
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).cgPath
        ring.strokeColor = Style.soft.withAlphaComponent(0.5).resolvedColor(with: traitCollection).cgColor
    }
}

/// "Likely this month", over the empty circles.
final class LikelyHeader: UICollectionReusableView {
    private let title = SectionTitle("Likely this month")
    private let detail = UILabel(font: Style.footnote, color: Style.soft)

    override init(frame: CGRect) {
        super.init(frame: frame)
        let stack = UIStackView(arrangedSubviews: [title, detail])
        stack.axis = .vertical
        stack.spacing = 2
        pin(stack, insets: UIEdgeInsets(top: 0, left: 0, bottom: 12, right: 0))
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(month: String?) {
        let name = month.flatMap { Yard.calendar.date(of: $0 + "-15") }.map(Words.month.string) ?? "this month"
        detail.text = "Not seen here yet. Claude's list of local feeder birds for \(name)."
    }
}

/// One likely bird: what to look or listen for, and its field guide.
final class LikelyViewController: UIViewController {
    private let bird: Likely.Hope

    init(_ bird: Likely.Hope) {
        self.bird = bird
        super.init(nibName: nil, bundle: nil)
        title = bird.name
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Style.page
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        let chance = UILabel(font: Style.footnote, color: Style.soft)
        chance.text = "\(bird.chance.capitalizedFirst) at feeders here this month · not seen here yet"
        let latin = UILabel(font: Style.italic(Style.prose), color: Style.soft)
        latin.text = bird.scientific
        latin.isHidden = bird.scientific == nil
        let note = UILabel(font: Style.prose)
        note.attributedText = Words.bolded(bird.note, font: Style.prose, lineHeight: Style.proseLeading)
        var actions: [ActionTiles.Action] = []
        if let guide = bird.guide {
            actions.append(.init(title: "Field guide", symbol: "book.closed") { [weak self] in self?.open(link: guide) })
            actions.append(.init(title: "Its sounds", symbol: "waveform") { [weak self] in
                self?.open(link: guide.appendingPathComponent("sounds"))
            })
        }
        let stack = UIStackView(arrangedSubviews: [latin, Panel([note, chance], spacing: 8), ActionTiles(actions)])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Style.gutter),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Style.gutter),
        ])
    }
}
