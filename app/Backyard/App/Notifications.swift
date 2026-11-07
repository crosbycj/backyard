import BackgroundTasks
import os
import UIKit
import UserNotifications
import YardModel
import YardStore

/// Notifications, from the phone's side. The collector decides what's worth
/// telling (collector/notify.py) from the switches this phone sends it;
/// this asks iOS, gives the collector the address, and does what a tap or
/// an answer means.
///
/// Nothing asks on first launch. iOS's provisional permission lets the
/// first ones arrive quietly in Notification Center, with its own Keep and
/// Turn Off, so they're found by getting a good one. The real question
/// comes from a bell (Today's switches, or following a bird), where the
/// person just said they want it.
@MainActor
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifications()
    /// Posted when what iOS allows changes.
    static let changed = Notification.Name("NotificationsChanged")
    typealias Kind = NotifySettings.Kind

    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "com.example.backyard", category: "notify")
    private(set) var status: UNAuthorizationStatus = .notDetermined
    /// Whether they may show as banners and on the Lock Screen. Not the
    /// same as the status: Keep, then Deliver Immediately, on a quiet one
    /// authorizes the app but leaves its notifications quiet (Apple,
    /// "Asking permission to use notifications").
    private(set) var alerts: UNNotificationSetting = .notSupported

    /// At launch: the answers a question offers, quiet delivery without
    /// asking, then the address.
    func start() {
        center.delegate = self
        let right = UNNotificationAction(identifier: "right", title: "That's right")
        let other = UNNotificationAction(identifier: "other", title: "Something else…", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "decide", actions: [right, other], intentIdentifiers: []),
        ])
        Task {
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .provisional, .providesAppNotificationSettings])
            }
            await refresh()
            UIApplication.shared.registerForRemoteNotifications()
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTask, using: nil) { task in
            Task { @MainActor in self.refreshInBackground(task as! BGAppRefreshTask) }
        }
    }

    /// What iOS allows now (the person may have changed it in Settings).
    func refresh() async {
        let settings = await center.notificationSettings()
        status = settings.authorizationStatus
        alerts = settings.alertSetting
        if var push = Yard.store.pushAddress(), push.status != status.word {
            push.status = status.word
            try? Yard.store.setPush(push)
            Yard.sendMarks()
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Apple gave this phone its address.
    func registered(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        let address = PushAddress(token: hex, env: Self.environment, status: status.word)
        guard address != Yard.store.pushAddress() else { return }
        try? Yard.store.setPush(address)
        Yard.sendMarks()
    }

    /// Which of Apple's services reaches this build: Xcode's builds (and the
    /// simulator) the sandbox, TestFlight and the App Store production. The
    /// build's profile says, when it has one.
    static var environment: String {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .isoLatin1),
              let key = text.range(of: "<key>aps-environment</key>") else { return "production" }
        return text[key.upperBound...].prefix(60).contains("development") ? "sandbox" : "production"
        #endif
    }

    // MARK: - Choosing

    var settings: NotifySettings { Yard.store.notifySettings() }

    /// Whether they come as banners, not only quietly or not at all.
    var prominent: Bool { (status == .authorized || status == .ephemeral) && alerts == .enabled }

    /// Turn a kind on, from the sheet or a bird's bell; this is where iOS
    /// is asked, the first time it matters.
    func turnOn(_ kind: Kind, follow bird: String? = nil, from screen: UIViewController?) {
        update {
            $0.kinds.insert(kind)
            if let bird { $0.follow.insert(bird) }
        }
        Task { await askForBanners(from: screen) }
    }

    func turnOff(_ kind: Kind) {
        update { $0.kinds.remove(kind) }
    }

    func unfollow(_ bird: String) {
        update { $0.follow.remove(bird) }
    }

    private func update(_ change: (inout NotifySettings) -> Void) {
        var s = settings
        change(&s)
        try? Yard.store.setNotify(s)
        UISelectionFeedbackGenerator().selectionChanged()
        Yard.sendMarks()
    }

    /// Ask iOS for banners and sounds, unless they're already allowed.
    /// iOS asks once and answers later requests itself; when the answer
    /// leaves them quiet without asking (they were kept quiet, or turned
    /// off), only Settings can change it, so that's where this points.
    /// Someone who just said Don't Allow isn't sent there.
    func askForBanners(from screen: UIViewController?) async {
        await refresh()
        guard !prominent else { return }
        if status != .denied {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .providesAppNotificationSettings])) ?? false
            await refresh()
            guard !prominent, granted else { return }
        }
        let off = status == .denied
        let alert = UIAlertController(
            title: off ? "Notifications are off for Backyard" : "Backyard's notifications arrive quietly",
            message: off ? "Turn them on in Settings, and this will come."
                : "To see them as banners and on the Lock Screen, turn those on for Backyard in Settings.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            UIApplication.shared.open(URL(string: UIApplication.openNotificationSettingsURLString)!)
        })
        screen?.present(alert, animated: true)
    }

    // MARK: - Arriving and answering

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        // In the app, a visit is coming in on the page; still say so.
        done([.banner, .list, .sound])
        Task { @MainActor in Yard.sync() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let open = (info["open"] as? String).flatMap(URL.init(string:))
        let visit = info["visit"] as? String, bird = info["bird"] as? String
        Task { @MainActor in
            switch action {
            case "right":
                // Your word that Claude's maybe was right: the same bird, as a correction.
                if let visit, let bird {
                    try? Yard.store.correct(Correction(visit: visit, name: bird))
                    try? await Yard.store.sendMarks()
                }
            case "other":
                if let visit { Doorway.open(URL(string: "backyard://visit/\(visit)?correct=1")!) }
            case UNNotificationDefaultActionIdentifier:
                if let open { Doorway.open(open) }
            default: break
            }
            done()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {
        Task { @MainActor in Doorway.open(URL(string: "backyard://settings/notifications")!) }
    }

    // MARK: - Noticing the archive has stopped

    /// The collector can't say it has stopped, so the phone notices: when
    /// iOS lets it look in the background, it syncs, and if the feed hasn't
    /// changed for STALE in the daytime, says so once.
    static let refreshTask = "com.example.backyard.refresh"
    private static let stale: TimeInterval = 2 * 3600
    private static let warnedKey = "notify.staleWarned"

    func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func refreshInBackground(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        let work = Task {
            await Yard.sync().value
            await checkStale()
            task.setTaskCompleted(success: Yard.lastError == nil)
        }
        task.expirationHandler = { work.cancel() }
    }

    func checkStale() async {
        guard Yard.lastError == nil, settings.kinds.contains(.broken),
              let generated = try? Yard.store.generatedAt(), Date().timeIntervalSince(generated) > Self.stale,
              (8..<20).contains(Calendar.current.component(.hour, from: .now)) else { return }
        let warned = UserDefaults.standard.object(forKey: Self.warnedKey) as? Date
        guard warned != generated else { return }
        UserDefaults.standard.set(generated, forKey: Self.warnedKey)
        let content = UNMutableNotificationContent()
        content.title = "The archive hasn't updated"
        content.body = "Nothing new from the collector since \(Words.clockWithHalf.string(from: generated)). "
            + "The Mac may be asleep, or the collector stopped."
        content.threadIdentifier = "feeder"
        content.userInfo = ["open": "backyard://today"]
        try? await center.add(UNNotificationRequest(identifier: "stale-\(Int(generated.timeIntervalSince1970))",
                                                    content: content, trigger: nil))
        log.info("warned the archive is stale")
    }
}

#if DEBUG
extension Notifications {
    /// `-notify delivered`: what's in Notification Center, with its photo or
    /// not, in the log (category notify).
    func logDelivered() async {
        let settings = await center.notificationSettings()
        log.info("status \(settings.authorizationStatus.word, privacy: .public), time-sensitive \(settings.timeSensitiveSetting.rawValue)")
        for n in await center.deliveredNotifications() {
            let c = n.request.content
            log.info("delivered: \(c.title, privacy: .public) | \(c.subtitle, privacy: .public) | \(c.attachments.count) photo(s) | \(c.interruptionLevel.rawValue) | \(c.categoryIdentifier, privacy: .public)")
        }
    }
}
#endif

extension UNAuthorizationStatus {
    /// As the collector reads it.
    var word: String {
        switch self {
        case .authorized: "authorized"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        case .denied: "denied"
        default: "notDetermined"
        }
    }
}
