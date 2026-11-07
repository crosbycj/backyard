import os
import UIKit
import YardModel

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Notifications.shared.start()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        Notifications.shared.registered(token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Logger(subsystem: "com.example.backyard", category: "notify")
            .error("no push address: \(String(describing: error), privacy: .public)")
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        Style.styleBars()
        Yard.watchConnection()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = RootViewController()
        window.tintColor = Style.accent
        window.makeKeyAndVisible()
        self.window = window
        connectionOptions.urlContexts.first.map { Doorway.open($0.url) }
        Doorway.openWaiting()
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        contexts.first.map { Doorway.open($0.url) }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        Yard.sync()
        Task { await Notifications.shared.refresh() }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        Notifications.shared.scheduleRefresh()
    }
}

/// The app's addresses, from the widget and from notifications:
///   backyard://visit/<id>          that visit, among its day's, over Today
///   backyard://visit/<id>?correct=1   ...with the sheet to say what it was
///   backyard://day/<yyyy-mm-dd>    the Journal at that day
///   backyard://bird/<key>          the bird
///   backyard://today               Today
///   backyard://settings/notifications   what to be told
@MainActor
enum Doorway {
    /// One that came before the window was up (a notification tapped at launch).
    private static var waiting: URL?

    private static var root: RootViewController? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?
            .rootViewController as? RootViewController
    }

    static func openWaiting() {
        if let url = waiting { waiting = nil; open(url) }
    }

    static func open(_ url: URL) {
        guard url.scheme == "backyard" else { return }
        guard let root else { waiting = url; return }
        let tail = url.pathComponents.dropFirst().first
        func tab(_ index: Int) -> UINavigationController? {
            root.presentedViewController?.dismiss(animated: true)
            root.tabs.selectedIndex = index
            let nav = root.tabs.selectedViewController as? UINavigationController
            nav?.popToRootViewController(animated: false)
            return nav
        }
        switch url.host {
        case "visit":
            guard let id = tail else { return }
            let correct = url.query?.contains("correct=1") == true
            Task {
                if (try? Yard.store.visit(id)) == nil { await Yard.sync().value }
                guard let visit = try? Yard.store.visit(id) else { return }
                root.tabs.selectedIndex = 0
                guard let nav = root.tabs.selectedViewController as? UINavigationController else { return }
                let day = Yard.calendar.day(of: visit.at)
                let others = ((try? Yard.store.visits(.journal)) ?? []).filter { Yard.calendar.day(of: $0.at) == day }
                nav.topViewController?.open(visit: visit, among: others)
                if correct {
                    // Once the card has grown into place.
                    try? await Task.sleep(for: .seconds(0.7))
                    (CardStage.shared?.top as? VisitCard)?.showing?.correct()
                }
            }
        case "day":
            guard let day = tail else { return }
            Task {
                if (try? Yard.store.days(.journal))?.contains(where: { $0.day == day }) != true { await Yard.sync().value }
                (tab(1)?.topViewController as? JournalViewController)?.scroll(to: day)
            }
        case "bird":
            tab(2)?.topViewController?.open(bird: tail)
        case "today":
            _ = tab(0)
        case "settings":
            guard root.presentedViewController == nil else { return }
            root.present(NotificationsViewController.sheet(), animated: true)
        default: break
        }
    }
}

/// The tabs, and over them the stage where visits open as cards.
final class RootViewController: UIViewController {
    let tabs = RootTabBarController()
    let stage = CardStage()

    override func viewDidLoad() {
        super.viewDidLoad()
        for child in [tabs, stage] as [UIViewController] {
            addChild(child)
            child.view.frame = view.bounds
            child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(child.view)
            child.didMove(toParent: self)
        }
    }

    override var childForStatusBarStyle: UIViewController? { stage.top ?? tabs }
}

/// Today · Journal · Birds. Today is the front page; the Journal (with
/// its favorites behind the heart) and the Birds are the record.
final class RootTabBarController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()
        viewControllers = [
            tab(TodayViewController(), "Today", "sun.max"),
            tab(JournalViewController(lens: .journal, title: "Journal"), "Journal", "book"),
            tab(BirdsViewController(), "Birds", "bird"),
        ]
        Yard.sync()
    }

    #if DEBUG
    /// For screenshots without touching the screen: `-tab 1` picks a tab,
    /// `-open <visit id>` opens a visit there, `-bird <key>` opens a bird,
    /// and `-scroll <points>` scrolls what opened down.
    private var opened = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !opened else { return }
        opened = true
        let args = UserDefaults.standard
        if args.object(forKey: "tab") != nil { selectedIndex = args.integer(forKey: "tab") }
        if args.string(forKey: "widgets") != nil { Task { await WidgetPreview.render() } }
        // `-notify sheet` opens what to be told; `-notify delivered` logs what iOS holds.
        switch args.string(forKey: "notify") {
        case "sheet": Doorway.open(URL(string: "backyard://settings/notifications")!)
        case "delivered": Task { await Notifications.shared.logDelivered() }
        default: break
        }
        // `-favorites yes` shows the Journal's favorites; `-monthsBack 1` steps its calendar back.
        if let journal = (selectedViewController as? UINavigationController)?.topViewController as? JournalViewController {
            if args.string(forKey: "favorites") != nil { journal.debugToggleFavorites() }
            if args.object(forKey: "monthsBack") != nil { journal.debugStep(month: -args.integer(forKey: "monthsBack")) }
        }
        if args.string(forKey: "hammer") != nil, let today = (selectedViewController as? UINavigationController)?.topViewController {
            Task {
                await Yard.sync().value
                await Hammer.run(on: today)
            }
            return
        }
        guard args.string(forKey: "open") != nil || args.string(forKey: "bird") != nil else {
            let down = CGFloat(args.double(forKey: "scroll"))
            if down > 0, let root = (selectedViewController as? UINavigationController)?.topViewController,
               let scroll = root.view.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
                Task {
                    await Yard.sync().value
                    // The large title first, as a finger would fold it: a jump that
                    // folds it too reads as "still at the top" and is put back.
                    scroll.contentOffset.y += 60
                    try? await Task.sleep(for: .seconds(0.3))
                    root.view.layoutIfNeeded()
                    scroll.contentOffset.y = min(scroll.contentOffset.y + down - 60,
                                                 scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                    // `-shade yes` pulls the Journal's month down once it's scrolled.
                    if args.string(forKey: "shade") != nil, let journal = root as? JournalViewController {
                        try? await Task.sleep(for: .seconds(0.5))
                        journal.debugOpenShade()
                    }
                }
            }
            return
        }
        Task {
            await Yard.sync().value
            guard let nav = selectedViewController as? UINavigationController else { return }
            var screen: UIViewController?
            if let id = args.string(forKey: "open"), let visit = try? Yard.store.visit(id) {
                // As the journal opens it: a card among the journal's visits.
                let all = (try? Yard.store.visits(.journal)) ?? []
                let card = VisitCard(visits: all.filter { $0.source != .report }, start: visit.id, at: nil)
                CardStage.shared?.open(card, from: nil, showing: nil, animated: false)
                screen = card.showing
            } else if let key = args.string(forKey: "bird"), let bird = try? Yard.store.bird(key) {
                screen = JournalViewController(lens: Lens(bird: key), title: bird.name)
                nav.pushViewController(screen!, animated: false)
            }
            guard let screen else { return }
            // `-sheet correct` shows the correction sheet; `-correct <name>` says
            // the visit's bird is that one, as picking it in the sheet would.
            if let visit = screen as? VisitViewController {
                if args.string(forKey: "sheet") == "correct" { visit.correct() }
                // `-save photo` or `-save video`: Save to Photos from the menu.
                if let what = args.string(forKey: "save") { visit.saveToPhotos(video: what == "video") }
                // `-play yes` plays the video fullscreen from the photo on show.
                if args.string(forKey: "play") != nil {
                    try? await Task.sleep(for: .seconds(2))
                    visit.playFullscreen()
                }
                if let name = args.string(forKey: "correct"), let id = args.string(forKey: "open") {
                    try? Yard.store.correct(Correction(visit: id, name: name))
                    Yard.sendMarks()
                }
            }
            let down = CGFloat(args.double(forKey: "scroll"))
            if down > 0, let scroll = screen.view.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
                // After a card has settled into its size.
                try? await Task.sleep(for: .seconds(1))
                screen.view.layoutIfNeeded()
                scroll.contentOffset.y = min(scroll.contentOffset.y + down,
                                             scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            }
        }
    }
    #endif

    private func tab(_ root: UIViewController, _ title: String, _ symbol: String) -> UINavigationController {
        let nav = UINavigationController(rootViewController: root)
        nav.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: symbol),
                                      selectedImage: UIImage(systemName: symbol + ".fill"))
        nav.navigationBar.prefersLargeTitles = true
        return nav
    }
}
