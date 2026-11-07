import UIKit
import YardModel

/// A visit over where you were, so it's clear you've stepped into one thing
/// and can put it back: it grows out of the photo you tapped, and a swipe
/// down shrinks it back in (CardStage). Drag sideways to the visit before
/// or after it among the ones it was opened from (the day's, the bird's,
/// what was saved), oldest to newest like a camera roll; the next visit
/// follows your finger.
final class VisitCard: UINavigationController {
    private let pages: VisitPages
    /// The visit it opened on: it goes back into that one's photo.
    let openedVisit: String

    init(visits: [Visit], start: String, at media: String?) {
        pages = VisitPages(visits: visits, start: start, at: media)
        openedVisit = start
        super.init(rootViewController: pages)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The visit showing now, if nothing's pushed over it (it may not be the
    /// one it opened on).
    var showing: VisitViewController? {
        viewControllers.count == 1 ? pages.viewControllers?.first as? VisitViewController : nil
    }

    /// What fades in once it's open and out as it shrinks: the bar, and the
    /// buttons on the photo.
    var chrome: [UIView] { [navigationBar] + (showing?.chrome ?? []) }

    /// The screen's safe area, kept whatever the card's size or place: as it
    /// grows, shrinks or follows a finger it only scales, and never lays out
    /// again (which would shift the bar and the photo inside it).
    var fullScreenSafeArea: UIEdgeInsets? {
        didSet { viewSafeAreaInsetsDidChange() }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        guard let want = fullScreenSafeArea, isViewLoaded else { return }
        let extra = additionalSafeAreaInsets, now = view.safeAreaInsets
        let need = UIEdgeInsets(top: want.top - (now.top - extra.top), left: want.left - (now.left - extra.left),
                                bottom: want.bottom - (now.bottom - extra.bottom), right: want.right - (now.right - extra.right))
        if need != extra { additionalSafeAreaInsets = need }
    }

    override func accessibilityPerformEscape() -> Bool {
        closeCard()
        return true
    }

    /// Whether the visit showing is scrolled to its top, and nothing is
    /// pushed over it: then a swipe down puts the whole thing away.
    var atTop: Bool {
        viewControllers.count == 1 && ((pages.viewControllers?.first as? VisitViewController)?.atTop ?? true)
    }
}

final class VisitPages: UIPageViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    private let visits: [Visit]
    private var index: Int

    init(visits: [Visit], start: String, at media: String?) {
        self.visits = visits.sorted { $0.at < $1.at }
        index = self.visits.firstIndex { $0.id == start } ?? 0
        super.init(transitionStyle: .scroll, navigationOrientation: .horizontal,
                   options: [.interPageSpacing: 16])
        let first = VisitViewController(visit: self.visits[index], startAt: media)
        setViewControllers([first], direction: .forward, animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Style.page
        dataSource = visits.count > 1 ? self : nil
        delegate = self
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.closeCard()
        })
        // Swiping between visits is the page view's own scroll, so the next
        // visit follows the finger. Over the photos, the photos let a drag go
        // when it starts at the edge or runs past the first or last (PhotoStrip).
        current?.becameCurrent(of: self)
    }

    private var current: VisitViewController? { viewControllers?.first as? VisitViewController }

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerBefore viewController: UIViewController) -> UIViewController? {
        page(after: viewController, by: -1)
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerAfter viewController: UIViewController) -> UIViewController? {
        page(after: viewController, by: 1)
    }

    private func page(after viewController: UIViewController, by step: Int) -> UIViewController? {
        guard let visit = viewController as? VisitViewController,
              let i = visits.firstIndex(where: { $0.id == visit.visitID }),
              visits.indices.contains(i + step) else { return nil }
        return VisitViewController(visit: visits[i + step], startAt: nil)
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let page = current, let i = visits.firstIndex(where: { $0.id == page.visitID }) else { return }
        index = i
        page.becameCurrent(of: self)
    }

    /// No words in the bar: it floats on the photo, where only glass reads
    /// well. The day and time are under the photo.
    func showTitle(for visit: Visit) {
        navigationItem.title = nil
    }
}
