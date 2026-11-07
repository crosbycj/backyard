import UIKit
import YardModel
import YardStore

/// "Not a crow? What is it?" The yard's birds to pick from, or any name
/// typed in. The phone keeps the answer and sends it to the collector,
/// which has Claude rewrite the visit around it; the visit says so until then.
final class CorrectViewController: UITableViewController, UISearchResultsUpdating {
    private let visit: Visit
    private let birds: [Bird]
    private var typed = ""

    init(visit: Visit) {
        self.visit = visit
        let current = Set(visit.birds.compactMap(\.bird))
        birds = ((try? Yard.store.birds()) ?? []).filter { !current.contains($0.key) }
        super.init(style: .insetGrouped)
        title = "What is it?"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = Style.page
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "bird")
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Another bird's name"
        search.searchBar.autocapitalizationType = .words
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    private var shown: [Bird] {
        typed.isEmpty ? birds : birds.filter { $0.name.localizedCaseInsensitiveContains(typed) }
    }

    private var offersTyped: Bool {
        !typed.isEmpty && !birds.contains { $0.name.caseInsensitiveCompare(typed) == .orderedSame }
    }

    func updateSearchResults(for searchController: UISearchController) {
        typed = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespaces)
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        shown.count + (offersTyped ? 1 : 0)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "Claude said \(visit.bird?.name ?? "something else"). It's really…"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Claude looks at the photos again with your answer and rewrites this visit. The board, the story and the yard list follow on the collector's next run."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "bird", for: indexPath)
        var content = cell.defaultContentConfiguration()
        if offersTyped && indexPath.row == shown.count {
            content.text = "“\(typed)”"
            content.secondaryText = "Use this name"
        } else {
            let bird = shown[indexPath.row]
            content.text = bird.name
            content.secondaryText = bird.scientific
            content.secondaryTextProperties.font = Style.italic(Style.footnote)
        }
        content.secondaryTextProperties.color = Style.soft
        cell.contentConfiguration = content
        cell.backgroundColor = Style.card
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let name = offersTyped && indexPath.row == shown.count ? typed : shown[indexPath.row].name
        try? Yard.store.correct(Correction(visit: visit.id, name: name))
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Yard.sendMarks()
        dismiss(animated: true)
    }
}
