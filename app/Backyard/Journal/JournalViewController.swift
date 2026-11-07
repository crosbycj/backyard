import UIKit
import YardModel
import YardStore

/// The story of the yard through a lens, newest day first. The whole
/// journal opens with the month as a calendar of faces, which folds to the
/// week you're reading as you scroll and stays under the bar; each day is one
/// group: Claude's note for it, its reel, then its visits as they came. The
/// journal, its favorites and one bird's are all this screen with a
/// different lens; a bird's opens with the bird itself.
final class JournalViewController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    enum Item: Hashable {
        case bird(String)
        case calendar
        case note(String)
        case reel(String)
        case visit(String)
    }

    private static let about = "about"
    private static let calendar = "calendar"

    private(set) var lens: Lens
    private var days: [String: Day] = [:]
    private var visits: [String: Visit] = [:]
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, Item>!
    private let empty = UILabel(font: Style.subheadline, color: Style.soft)
    private var pendingDay: String?
    /// The month: on the page, then folded under the bar.
    private let shade = MonthShade()
    private var shadeTop: NSLayoutConstraint!
    /// The room the month takes on the page, whole, with its margins.
    private var room: CGFloat = 420
    private static let below: CGFloat = 8
    /// The day at the top of what you're reading.
    private var reading: String?
    private var folded = false

    init(lens: Lens, title: String) {
        self.lens = lens
        super.init(nibName: nil, bundle: nil)
        self.title = title
        navigationItem.largeTitleDisplayMode = .always
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Style.page
        collectionView = JournalCollectionView(frame: view.bounds, collectionViewLayout: layout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = Style.page
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.refreshControl = UIRefreshControl(frame: .zero, primaryAction: UIAction { [weak self] _ in
            Task {
                await Yard.sync().value
                self?.collectionView.refreshControl?.endRefreshing()
            }
        })
        view.addSubview(collectionView)
        configureDataSource()

        empty.textAlignment = .center
        empty.numberOfLines = 0
        view.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            empty.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
        ])

        if lens.bird == nil {
            showFavoritesButton()
            // In the list, so a drag on it scrolls the journal; pinned to
            // the list's frame, so it can stay put while the page moves.
            collectionView.addSubview(shade)
            shade.layer.zPosition = 100
            let frame = collectionView.frameLayoutGuide
            shadeTop = shade.topAnchor.constraint(equalTo: frame.topAnchor)
            NSLayoutConstraint.activate([
                shadeTop,
                shade.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: Style.gutter),
                shade.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -Style.gutter),
            ])
            collectionView.panGestureRecognizer.require(toFail: shade.pull)
            shade.month.onDay = { [weak self] day in
                self?.scroll(to: day)
                self?.shade.fold(open: false)
            }
            shade.month.onMonth = { [weak self] by in self?.stepShade(month: by) }
            shade.onFold = { [weak self] in self?.updateShade(again: true) }
            shade.onMeasure = { [weak self] in DispatchQueue.main.async { self?.fitRoom() } }
        } else {
            showFollowButton()
            NotificationCenter.default.addObserver(forName: Notifications.changed, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.showFollowButton() }
            }
        }
        for name in [YardStore.didChange, CallPlayer.changed] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
        reload()
    }

    // MARK: - Following

    /// The bell on a bird's page: be told when it comes. The first ring is
    /// where iOS asks, if it hasn't.
    private func showFollowButton() {
        guard let key = lens.bird else { return }
        let settings = Notifications.shared.settings
        let following = settings.follow.contains(key) && settings.kinds.contains(.follow)
        let item = UIBarButtonItem(image: UIImage(systemName: following ? "bell.fill" : "bell"),
                                   primaryAction: UIAction { [weak self] _ in
            if following { Notifications.shared.unfollow(key) }
            else { Notifications.shared.turnOn(.follow, follow: key, from: self) }
            self?.showFollowButton()
        })
        item.accessibilityLabel = following ? "Stop following" : "Follow: be told when it comes"
        navigationItem.rightBarButtonItem = item
    }

    // MARK: - Favorites

    /// The heart in the bar: only the visits you loved, or everything.
    private func showFavoritesButton() {
        let item = UIBarButtonItem(image: UIImage(systemName: lens.kept ? "heart.fill" : "heart"),
                                   primaryAction: UIAction { [weak self] _ in self?.toggleFavorites() })
        item.accessibilityLabel = lens.kept ? "Show all visits" : "Show favorites"
        navigationItem.rightBarButtonItem = item
    }

    private func toggleFavorites() {
        lens = Lens(kept: !lens.kept)
        // The bar's title only: the tab stays the Journal.
        navigationItem.title = lens.kept ? "Favorites" : "Journal"
        showFavoritesButton()
        UISelectionFeedbackGenerator().selectionChanged()
        reload()
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
    }

    // MARK: - Contents

    func reload() {
        let list = (try? Yard.store.days(lens)) ?? []
        days = Dictionary(uniqueKeysWithValues: list.map { ($0.day, $0) })
        visits = Dictionary(list.flatMap(\.visits).map { ($0.id, $0) }) { a, _ in a }
        var snapshot = NSDiffableDataSourceSnapshot<String, Item>()
        if let bird = lens.bird {
            snapshot.appendSections([Self.about])
            snapshot.appendItems([.bird(bird)], toSection: Self.about)
        } else if !lens.kept, let latest = list.first {
            // Room on the page for the month, which lies over it.
            snapshot.appendSections([Self.calendar])
            snapshot.appendItems([.calendar], toSection: Self.calendar)
            if reading.flatMap({ days[$0] }) == nil { reading = latest.day }
        }
        for day in list {
            snapshot.appendSections([day.day])
            var items: [Item] = []
            if day.note != nil { items.append(.note(day.day)) }
            if day.reel != nil { items.append(.reel(day.day)) }
            items += day.visits.map { .visit($0.id) }
            snapshot.appendItems(items, toSection: day.day)
        }
        let shown = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { shown.indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
        empty.isHidden = !list.isEmpty || lens.bird != nil
        empty.text = lens.kept
            ? "No favorites yet.\nTap ♡ on a visit to keep it here."
            : "Nothing here yet.\nThe feed comes in on the next sync."
        if let day = pendingDay { scroll(to: day) }
        follow()
        updateShade(again: true)
    }

    /// Bring a day's header to the top.
    func scroll(to day: String) {
        guard isViewLoaded, let section = dataSource.snapshot().indexOfSection(day) else { pendingDay = day; return }
        pendingDay = nil
        collectionView.layoutIfNeeded()
        let path = IndexPath(item: 0, section: section)
        if let header = collectionView.layoutAttributesForSupplementaryElement(
            ofKind: UICollectionView.elementKindSectionHeader, at: path) {
            // Under the month, folded.
            let top = header.frame.minY - collectionView.adjustedContentInset.top - (shadeAllowed ? 6 + shade.foldedHeight : 0)
            collectionView.setContentOffset(CGPoint(x: 0, y: max(top, -collectionView.adjustedContentInset.top)), animated: false)
        }
    }

    /// On or back to the next month the journal has visits in, skipping
    /// empty ones. It comes back to the day you're reading when it folds.
    private func stepShade(month by: Int) {
        guard let shown = shade.shown, let to = neighbor(of: shown, by: by) else { return }
        shade.show(month: to, days: days, canBack: neighbor(of: to, by: -1) != nil,
                   canNext: neighbor(of: to, by: 1) != nil, day: reading)
    }

    /// The nearest month before (-1) or after (1) this one with visits: noon on its 15th.
    private func neighbor(of month: Date, by: Int) -> Date? {
        let here = String(Yard.calendar.day(of: month).prefix(7))
        let months = Set(days.keys.map { String($0.prefix(7)) }).sorted()
        let found = by < 0 ? months.last { $0 < here } : months.first { $0 > here }
        return found.flatMap { Yard.calendar.date(of: $0 + "-15") }
    }

    // MARK: - The month

    private var shadeAllowed: Bool { lens.bird == nil && !lens.kept }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { follow() }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if shade.isPulled { shade.fold(open: false) }
    }

    /// The month rides on its room in the page and folds as the room goes
    /// under the bar, then stays there, on the day you're reading: the one
    /// whose rows are at its edge.
    private func follow() {
        let snapshot = dataSource.snapshot()
        guard shadeAllowed, let section = snapshot.indexOfSection(Self.calendar),
              let place = collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: section)) else {
            shade.isShown = false
            return
        }
        shade.isShown = true
        let y = collectionView.contentOffset.y
        // Down with the page when it's pulled past its top, for the refresh.
        let top = max(view.safeAreaInsets.top, place.frame.minY - y) + 6
        shadeTop.constant = top
        shade.reveal(place.frame.maxY - y - Self.below - top)
        if (shade.open == 0) != folded {
            folded = shade.open == 0
            if folded { updateShade() }
        }
        let edge = y + top + shade.foldedHeight
        // From the layout, not the visible cells: those lag a scroll set in code.
        let around = CGRect(x: 0, y: edge - collectionView.bounds.height, width: collectionView.bounds.width,
                            height: 2 * collectionView.bounds.height)
        let shown = (collectionView.collectionViewLayout.layoutAttributesForElements(in: around) ?? [])
            .filter { $0.indexPath.section != section }
        let at = shown.filter { $0.frame.minY <= edge }.max { $0.frame.minY < $1.frame.minY }
            ?? shown.min { $0.frame.minY < $1.frame.minY }
        guard let day = at.flatMap({ dataSource.sectionIdentifier(for: $0.indexPath.section) }), day != reading else { return }
        reading = day
        updateShade()
    }

    /// The month the reading day is in. While it's open it only moves the
    /// mark, so the month doesn't change under the finger.
    private func updateShade(again: Bool = false) {
        guard shadeAllowed, let reading, let date = Yard.calendar.date(of: reading) else { return }
        if shade.open > 0, !again {
            shade.month.mark(reading)
            return
        }
        shade.show(month: date, days: days, canBack: neighbor(of: date, by: -1) != nil,
                   canNext: neighbor(of: date, by: 1) != nil, day: reading, again: again)
    }

    /// Make the month's room on the page fit it: five weeks or six. Once
    /// it's under the bar the page moves by the same amount, so what you're
    /// reading stays where it is.
    private func fitRoom() {
        let height = 6 + shade.openHeight + Self.below
        guard abs(height - room) > 0.5 else { return }
        let away = !shade.isOnPage
        let change = height - room
        room = height
        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.layoutIfNeeded()
        if away { collectionView.contentOffset.y += change }
        follow()
    }

    // MARK: - Layout

    private func layout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            let id = self?.dataSource.sectionIdentifier(for: index)
            if id == Self.calendar {
                // The month's room: the month itself lies over it.
                let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(self?.room ?? 420))
                let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
                return NSCollectionLayoutSection(group: group)
            }
            if id == Self.about {
                // The bird: on the page, no day over it.
                let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(400))
                let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
                let section = NSCollectionLayoutSection(group: group)
                section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0)
                return section
            }
            // A day: one rounded group, its name over it.
            var list = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            list.backgroundColor = .clear
            list.headerMode = .supplementary
            list.separatorConfiguration.color = Style.rule
            let section = NSCollectionLayoutSection.list(using: list, layoutEnvironment: environment)
            section.contentInsets.leading = Style.gutter
            section.contentInsets.trailing = Style.gutter
            return section
        }
    }

    private func configureDataSource() {
        let bird = UICollectionView.CellRegistration<BirdHeaderCell, String> { [weak self] cell, _, key in
            guard let self, let bird = try? Yard.store.bird(key) else { return }
            cell.show(bird, visits: self.visits.values.filter { $0.source != .report }, from: self)
            cell.onOpen = { [weak self] visit, source in self?.open(visit: visit, among: self?.inOrder, from: source) }
        }
        let room = UICollectionView.CellRegistration<UICollectionViewCell, Item> { _, _, _ in }
        let note = UICollectionView.CellRegistration<DayNoteCell, String> { [weak self] cell, _, day in
            if let writing = self?.days[day]?.note { cell.show(writing) }
        }
        let reel = UICollectionView.CellRegistration<ReelCell, String> { [weak self] cell, _, day in
            guard let self, let reel = self.days[day]?.reel else { return }
            cell.show(reel, from: self)
        }
        let visit = UICollectionView.CellRegistration<VisitCell, String> { [weak self] cell, _, id in
            if let visit = self?.visits[id] { cell.show(visit) }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, path, item in
            switch item {
            case .bird(let key): view.dequeueConfiguredReusableCell(using: bird, for: path, item: key)
            case .calendar: view.dequeueConfiguredReusableCell(using: room, for: path, item: item)
            case .note(let day): view.dequeueConfiguredReusableCell(using: note, for: path, item: day)
            case .reel(let day): view.dequeueConfiguredReusableCell(using: reel, for: path, item: day)
            case .visit(let id): view.dequeueConfiguredReusableCell(using: visit, for: path, item: id)
            }
        }
        let header = UICollectionView.SupplementaryRegistration<DayHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, path in
            guard let self, let key = self.dataSource.sectionIdentifier(for: path.section) else { return }
            view.show(key, visits: self.days[key]?.visits ?? [])
        }
        dataSource.supplementaryViewProvider = { view, _, path in
            view.dequeueConfiguredReusableSupplementary(using: header, for: path)
        }
    }

    // MARK: - Ahead of the finger

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let small = indexPaths.compactMap { path -> URL? in
            guard case .visit(let id) = dataSource.itemIdentifier(for: path) else { return nil }
            return Yard.store.url(visits[id]?.bestPhoto?.small)
        }
        ImageLoader.shared.prefetch(small, pixels: PhotoView.pixels(for: CGSize(width: 60, height: 60)))
    }

    // MARK: - Going in

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .visit(let id): visits[id]?.source != .report
        case .reel: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .visit(let id):
            guard let visit = visits[id] else { return }
            open(visit: visit, among: inOrder, from: (collectionView.cellForItem(at: indexPath) as? VisitCell)?.photo)
        case .reel:
            (collectionView.cellForItem(at: indexPath) as? ReelCell)?.play()
        default: break
        }
    }

    /// This lens's visits with photos, oldest first: what a card swipes through.
    private var inOrder: [Visit] {
        visits.values.filter { $0.source != .report }.sorted { $0.at < $1.at }
    }

    #if DEBUG
    func debugToggleFavorites() { loadViewIfNeeded(); toggleFavorites() }
    func debugStep(month by: Int) { loadViewIfNeeded(); stepShade(month: by) }
    func debugOpenShade() { shade.fold(open: true) }
    #endif
}

/// Drags that start on the month's days still scroll the journal.
private final class JournalCollectionView: UICollectionView {
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}



/// The journal's month. On the page it's the whole month; as the journal
/// scrolls it folds, the way Calendar folds a month into a week, down to
/// the week you're reading, and stays under the bar. Pull it down there for
/// the whole month again; a day takes you there, and scrolling folds it.
final class MonthShade: UIView {
    let month = MonthView()
    let pull = UIPanGestureRecognizer()
    /// After it's pushed back up: time to catch up with the day you're reading.
    var onFold: (() -> Void)?
    /// When its whole height changes: a month of five weeks or six.
    var onMeasure: (() -> Void)?
    /// The month it shows.
    private(set) var shown: Date?
    private var day: String?
    /// How much of it the page has room for, and how far it's pulled
    /// down past that: each 0 for the week to 1 for the whole month.
    private var revealed: CGFloat = 1
    private var pulled: CGFloat = 0

    private let glass: UIVisualEffectView
    /// The page's own card under it, so on the page it's a panel like the
    /// others; it turns to glass as it folds over the journal.
    private let card = UIView()
    private let clip = UIView()
    private let grabber = UIView()
    private var height: NSLayoutConstraint!
    private var shift: NSLayoutConstraint!
    private var week = CGRect(x: 0, y: 0, width: 0, height: 58)
    private var full: CGFloat = 380
    private var measured: CGFloat = 0
    private var start: CGFloat = 0
    private static let top: CGFloat = 14
    private static let bottom: CGFloat = 18

    init() {
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect()
            effect.isInteractive = true
            glass = UIVisualEffectView(effect: effect)
        } else {
            glass = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        glass.clipsToBounds = true
        glass.layer.cornerRadius = Style.radius
        glass.layer.cornerCurve = .continuous
        pin(glass)
        card.backgroundColor = Style.card
        glass.contentView.pin(card)

        clip.clipsToBounds = true
        clip.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(clip)
        clip.addSubview(month)
        grabber.backgroundColor = Style.soft.withAlphaComponent(0.45)
        grabber.layer.cornerRadius = 2.5
        grabber.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(grabber)

        height = heightAnchor.constraint(equalToConstant: Self.top + full + Self.bottom)
        shift = month.topAnchor.constraint(equalTo: clip.topAnchor)
        NSLayoutConstraint.activate([
            height,
            clip.topAnchor.constraint(equalTo: topAnchor, constant: Self.top),
            clip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Style.inset),
            clip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Style.inset),
            clip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.bottom),
            shift,
            month.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            month.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            grabber.centerXAnchor.constraint(equalTo: centerXAnchor),
            grabber.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            grabber.widthAnchor.constraint(equalToConstant: 36),
            grabber.heightAnchor.constraint(equalToConstant: 5),
        ])

        pull.addTarget(self, action: #selector(pan))
        addGestureRecognizer(pull)
        alpha = 0
        isUserInteractionEnabled = false
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Show the whole month") { [weak self] _ in self?.fold(open: true); return true },
            UIAccessibilityCustomAction(name: "Fold to the week") { [weak self] _ in self?.fold(open: false); return true },
        ]
    }

    required init?(coder: NSCoder) { fatalError() }

    /// How open it shows: as much as the page has room for, or as far as
    /// it's pulled.
    var open: CGFloat { max(revealed, pulled) }
    /// Some of its room is still on the page.
    var isOnPage: Bool { revealed > 0 }
    /// Pulled down over the journal.
    var isPulled: Bool { pulled > 0 }
    /// Its height whole, and folded to a week.
    var openHeight: CGFloat { Self.top + full + Self.bottom }
    var foldedHeight: CGFloat { Self.top + week.height + Self.bottom }

    /// Off for favorites and a bird's journal, which have no month.
    var isShown = false {
        didSet {
            guard isShown != oldValue else { return }
            isUserInteractionEnabled = isShown
            if !isShown { pulled = 0; apply() }
            alpha = isShown ? 1 : 0
        }
    }

    /// The room the page leaves it, from its top.
    func reveal(_ room: CGFloat) {
        let range = openHeight - foldedHeight
        revealed = range > 0 ? min(max((room - foldedHeight) / range, 0), 1) : 1
        apply()
    }

    /// Show `month`, folding to the week of `day`. The calendar is only
    /// rebuilt when its month changes, or when `again` (new data).
    func show(month date: Date, days: [String: Day], canBack: Bool, canNext: Bool, day: String?, again: Bool = false) {
        let same = shown.map { Yard.calendar.calendar.isDate($0, equalTo: date, toGranularity: .month) } ?? false
        if !same || again {
            shown = date
            month.show(month: date, days: days, canBack: canBack, canNext: canNext)
        }
        self.day = day
        month.mark(day)
        layoutIfNeeded()
        measure()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Its first real width, or a new one: the month's rows change height.
        if bounds.width != measured, shown != nil { measure() }
    }

    private func measure() {
        measured = bounds.width
        clip.layoutIfNeeded()
        let old = full
        full = max(month.bounds.height, 1)
        // A day outside the month it shows (it was stepped) folds to its last week.
        let fallback = CGRect(x: 0, y: full - week.height, width: month.bounds.width, height: week.height)
        week = day.flatMap { month.week(of: $0) } ?? fallback
        apply()
        if full != old { onMeasure?() }
    }

    private func apply() {
        let open = self.open
        shift.constant = -week.minY * (1 - open)
        height.constant = Self.top + week.height + (full - week.height) * open + Self.bottom
        card.alpha = revealed * (1 - pulled)
    }

    // MARK: - The pull

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === pull else { return super.gestureRecognizerShouldBegin(recognizer) }
        // Only once it's folded under the bar, and only up and down: on the
        // page a drag scrolls the journal.
        let speed = pull.velocity(in: self)
        return abs(speed.y) > abs(speed.x) && (revealed == 0 || pulled > 0)
    }

    @objc private func pan(_ pan: UIPanGestureRecognizer) {
        let range = max(full - week.height, 1)
        switch pan.state {
        case .began:
            start = open
        case .changed:
            pulled = min(max(start + pan.translation(in: self).y / range, 0), 1)
            apply()
        case .ended, .cancelled:
            let speed = pan.velocity(in: self).y
            fold(open: abs(speed) > 300 ? speed > 0 : pulled > 0.5, speed: speed / range)
        default: break
        }
    }

    /// Pulled all the way down or pushed back up, carried on from the finger's speed.
    func fold(open: Bool, speed: CGFloat = 0) {
        let target: CGFloat = open ? 1 : 0
        let distance = max(revealed, target) - self.open
        guard distance != 0 else {
            pulled = target
            apply()
            return
        }
        UISelectionFeedbackGenerator().selectionChanged()
        UIView.animate(springDuration: 0.42, bounce: 0.1, initialSpringVelocity: speed / distance, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.pulled = target
            self.apply()
            self.superview?.layoutIfNeeded()
        } completion: { [weak self] _ in
            if !open { self?.onFold?() }
        }
    }
}
