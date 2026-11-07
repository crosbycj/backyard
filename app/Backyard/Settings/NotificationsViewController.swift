import UIKit
import YardModel
import YardStore

/// What to be told: a switch for each kind, nothing more. How each sounds,
/// and whether it comes through Focus, is iOS's (Settings › Notifications).
/// Opened from the bell on Today, and from iOS's own notification settings.
final class NotificationsViewController: UITableViewController {
    typealias Kind = NotifySettings.Kind

    private struct Row {
        var kind: Kind
        var title: String
        var detail: String
    }

    private let sections: [(String, [Row])] = [
        ("Visits", [
            Row(kind: .visit, title: "Every visit", detail: "Quietly, a bird's repeat visits folded into one"),
            Row(kind: .good, title: "The good ones", detail: "A photo at its best, or a bird back after weeks away"),
            Row(kind: .new, title: "New to the yard", detail: "A bird the yard list hasn't had"),
            Row(kind: .follow, title: "Birds you follow", detail: ""),
        ]),
        ("To read", [
            Row(kind: .note, title: "Tonight's note", detail: "Claude's note on the day, after sunset"),
            Row(kind: .story, title: "The week's story", detail: "On Sunday evening"),
        ]),
        ("The feeder", [
            Row(kind: .seed, title: "Seed running out", detail: "When the tray is probably empty"),
            Row(kind: .decide, title: "Help Claude decide", detail: "When Claude isn't sure what came, with answers to tap"),
            Row(kind: .broken, title: "Something's broken", detail: "The feeder offline or low, or the archive not updating"),
        ]),
    ]

    /// In a sheet, as Today's bell and the doorway open it.
    static func sheet() -> UINavigationController {
        let nav = UINavigationController(rootViewController: NotificationsViewController())
        nav.sheetPresentationController?.detents = [.large()]
        nav.sheetPresentationController?.prefersGrabberVisible = true
        nav.view.tintColor = Style.accent
        return nav
    }

    init() {
        super.init(style: .insetGrouped)
        title = "Notifications"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        for name in [Notifications.changed, YardStore.didChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tableView.reloadData() }
            }
        }
        Task { await Notifications.shared.refresh() }
    }

    // MARK: - What iOS allows, then the switches

    private enum Standing { case fine, quiet, off }

    private var standing: Standing {
        let n = Notifications.shared
        return n.status == .denied ? .off : n.prominent ? .fine : .quiet
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count + (standing == .fine ? 0 : 1)
    }

    /// The switches' section for a table section, past the one about iOS.
    private func switches(_ section: Int) -> Int? {
        let i = section - (standing == .fine ? 0 : 1)
        return i >= 0 ? i : nil
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switches(section).map { sections[$0].1.count } ?? 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switches(section).map { sections[$0].0 }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let i = switches(section) else {
            return standing == .off
                ? "Backyard can't send any until notifications are on in Settings."
                : "For now they arrive quietly in Notification Center, without a sound."
        }
        return i == sections.count - 1
            ? "How they sound, and whether they come through Focus, is up to iOS: Settings › Notifications › Backyard."
            : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        content.secondaryTextProperties.color = .secondaryLabel
        content.textToSecondaryTextVerticalPadding = 3
        guard let i = switches(indexPath.section) else {
            content.text = standing == .off ? "Open Settings" : "Show them as banners"
            content.textProperties.color = Style.accent
            cell.contentConfiguration = content
            cell.accessoryView = nil
            cell.selectionStyle = .default
            return cell
        }
        let row = sections[i].1[indexPath.row]
        let settings = Notifications.shared.settings
        content.text = row.title
        content.secondaryText = row.kind == .follow ? followed(settings) : row.detail
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        let toggle = UISwitch()
        toggle.isOn = settings.kinds.contains(row.kind)
        toggle.onTintColor = Style.accent
        toggle.addAction(UIAction { [weak self] action in
            guard let on = (action.sender as? UISwitch)?.isOn else { return }
            if on { Notifications.shared.turnOn(row.kind, from: self) } else { Notifications.shared.turnOff(row.kind) }
        }, for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }

    /// The birds followed, by name, or where following starts.
    private func followed(_ settings: NotifySettings) -> String {
        let names = settings.follow.compactMap { try? Yard.store.bird($0)?.name }.sorted()
        return names.isEmpty ? "None yet: tap the bell on a bird's page" : names.joined(separator: ", ")
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard switches(indexPath.section) == nil else { return }
        if standing == .off {
            UIApplication.shared.open(URL(string: UIApplication.openNotificationSettingsURLString)!)
        } else {
            Task { await Notifications.shared.askForBanners(from: self) }
        }
    }
}
