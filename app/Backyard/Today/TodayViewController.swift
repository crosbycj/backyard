import UIKit
import YardModel
import YardStore

/// The front page: today in the yard, the way the board on the wall tells
/// it, made for the hand. The readings and the day's line, today's visitors
/// to swipe through, the week's story, and the cards. Everything in it is a
/// door: a visitor opens its visit, a bird's name opens the bird, the day
/// opens the journal.
final class TodayViewController: UIViewController, UITextViewDelegate {
    /// How many visitors the carousel holds, reaching back days if it must.
    private static let carouselSize = 12
    private let scroll = UIScrollView()
    private let stack = UIStackView()

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Today"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Style.page
        // The page is the sky over the yard, as it is now.
        view.pin(SkyBackdrop())
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(heldWithTwo(_:)))
        hold.numberOfTouchesRequired = 2
        view.addGestureRecognizer(hold)
        navigationItem.largeTitleDisplayMode = .always
        // What to be told, and how to get here from iOS's own settings.
        let bell = UIBarButtonItem(image: UIImage(systemName: "bell"), primaryAction: UIAction { [weak self] _ in
            self?.present(NotificationsViewController.sheet(), animated: true)
        })
        bell.accessibilityLabel = "Notifications"
        navigationItem.rightBarButtonItem = bell
        scroll.alwaysBounceVertical = true
        scroll.refreshControl = UIRefreshControl(frame: .zero, primaryAction: UIAction { [weak self] _ in
            Task {
                await Yard.sync().value
                self?.scroll.refreshControl?.endRefreshing()
            }
        })
        view.pin(scroll)
        // The sky is the view's first subview, where the bar would look for
        // the scroll to follow; name it, so the large title still folds.
        setContentScrollView(scroll)
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        for name in [YardStore.didChange, CallPlayer.changed] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
        // Leaving the app counts as having looked; coming back measures from then.
        NotificationCenter.default.addObserver(self, selector: #selector(markLooked),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.view.window != nil else { return }
                self.seenSince = UserDefaults.standard.object(forKey: Self.lookedKey) as? Date
                self.reload()
            }
        }
        reload()
    }

    /// Holding the page with two fingers brings up a way to drag the sky
    /// through the day and try its weathers; again puts it away.
    private var scrubber: SkyScrubber?

    @objc private func heldWithTwo(_ hold: UILongPressGestureRecognizer) {
        if hold.state == .began { toggleScrubber() }
    }

    private func toggleScrubber() {
        if let scrubber {
            scrubber.removeFromSuperview()
            self.scrubber = nil
            return
        }
        let scrubber = SkyScrubber()
        view.addSubview(scrubber)
        NSLayoutConstraint.activate([
            scrubber.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Style.gutter),
            scrubber.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Style.gutter),
            scrubber.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
        self.scrubber = scrubber
    }

    private func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let wall = try? Yard.store.wall()
        Sky.shared.weather(wall?.now?.weather)
        let days = (try? Yard.store.days(.journal)) ?? []
        let today = Yard.calendar.day(of: .now)

        let birds = (try? Yard.store.birds()) ?? []
        let glance = Glance(visits: (try? Yard.store.visits(.journal)) ?? [], birds: birds,
                            now: .now, calendar: Yard.calendar)
        let night = wall?.now?.sunset == nil && wall?.now?.sunrise != nil

        // The date, then one line in the present tense, then the feeder as tiles.
        let date = UILabel(font: Style.subheadline, color: Style.soft)
        date.text = Words.longDate.string(from: .now)
        add(date, top: 2)
        let lede = Style.weight(Style.title, .regular)
        let line = UILabel(font: lede)
        line.attributedText = Words.bolded(nowLine(glance, wall: wall, night: night), font: lede, lineHeight: 1.1)
        add(line, top: 6)
        if let alert = wall?.now?.alert ?? ((try? Yard.store.feeder())??.state == "OFFLINE" ? "The feeder is offline." : nil) {
            let label = UILabel(font: Style.subheadline, color: Style.warn)
            label.text = alert
            add(Panel([label]), top: 14)
        }
        add(feederTiles(wall?.now), top: 14)
        // Claude's note for the day lives in the journal; this is the way there.
        if let note = days.first(where: { $0.day == today })?.note {
            add(Panel.rows([DoorRow("Tonight's note", detail: Words.firstSentence(note.text), symbol: "moon.stars") { [weak self] in
                self?.openJournal(at: today)
            }]), top: 10)
        }

        visitors(glance)
        sinceYouLooked(glance, days: days, today: today)
        expect(glance, night: night)
        worthALook(glance)

        if let story = try? Yard.store.story(weekOf: today) {
            add(SectionTitle("This week's story"), top: 30)
            add(Panel([storyView(story)]), top: 10)
        }

        let notes = wall?.notes ?? []
        if !notes.isEmpty { add(SectionTitle("From the board"), top: 30) }
        for note in notes {
            add(NoteCard(note: note, bird: bird(for: note, in: birds)) { [weak self] key in self?.open(bird: key) },
                top: 10)
        }

        if let synced = try? Yard.store.generatedAt() {
            let foot = UILabel(font: Style.footnote, color: Style.soft)
            foot.text = "Up to date with the archive as of \(Words.recently(synced)) at \(Words.clockWithHalf.string(from: synced))."
            foot.textAlignment = .center
            add(foot, top: 28)
        }
        add(UIView(), top: 32)
    }

    /// The board's readings as three tiles: the seed, the weather, the sun.
    private func feederTiles(_ readings: Wall.Readings?) -> UIView {
        var tiles: [UIView] = []
        // The seed as Claude last saw the tray, and when.
        if let seed = readings?.seed, let of = readings?.seedOf {
            let words = readings?.seedUntil.flatMap { $0.isEmpty ? nil : $0.capitalizedFirst } ?? "\(seed) of \(of)"
            tiles.append(FactTile("Seed", value: words, detail: readings?.seedSeen.map { "Seen \($0)" },
                                  accessory: SeedGauge(level: seed, of: of), warn: seed <= 1))
        }
        if let weather = readings?.weather {
            let parts = weather.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            tiles.append(FactTile(parts.count > 1 ? parts[1].capitalizedFirst : "Weather", value: parts[0]))
        }
        if let sunset = readings?.sunset { tiles.append(FactTile("Sunset", value: sunset)) }
        else if let sunrise = readings?.sunrise { tiles.append(FactTile("Sunrise", value: sunrise)) }
        let row = UIStackView(arrangedSubviews: tiles)
        row.distribution = .fillEqually
        row.alignment = .fill
        row.spacing = 8
        return row
    }

    // MARK: - Who came today

    /// Today's birds as faces, the most visits first: each a door to the bird.
    private func visitors(_ glance: Glance) {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for visit in glance.todays where visit.source != .report {
            guard let key = visit.bird?.bird else { continue }
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }
        guard !order.isEmpty else { return }
        let ranked = order.sorted { counts[$0]! > counts[$1]! }
        add(SectionTitle("Today's visitors"), top: 30)
        add(FaceRow(ranked.compactMap { key in glance.bird(key).map { ($0, counts[key]!) } }) { [weak self] key in
            self?.open(bird: key)
        }, inset: false, top: 10)
    }

    // MARK: - Now

    /// The yard right now, in a sentence worked out on the phone, not
    /// Claude's note (that's the journal's).
    private func nowLine(_ glance: Glance, wall: Wall?, night: Bool) -> String {
        let todays = glance.todays
        let last = glance.visits.last
        func who(_ visit: Visit) -> String {
            let name = visit.bird?.name ?? "visitor"
            return "\(Words.article(name)) **\(name)**"
        }
        if night {
            guard let last, Yard.calendar.day(of: last.at) == Yard.calendar.day(of: .now) else {
                return "The feeder is asleep until sunrise at \(wall?.now?.sunrise ?? "dawn")."
            }
            return "The feeder is resting for the night. \(Words.count(todays.count, "visit")) today; "
                + "the last, \(who(last).lowercasedFirst), at \(Words.clockWithHalf.string(from: last.at))."
        }
        if let last, wall?.now?.seed == 0 {
            return "Quiet since \(Words.since(last.at)). The seed's probably out."
        }
        guard let latest = todays.last else { return "No birds yet today." }
        return "\(Words.count(todays.count, "visit").capitalizedFirst) today, the last \(who(latest).lowercasedFirst) \(Words.ago(latest.at))."
    }

    // MARK: - Since you last looked

    /// When Today was last put away; what came after it is new.
    private static let lookedKey = "today.lastLooked"
    private var seenSince: Date?
    private var shownAt: Date?

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // New is measured from the last time Today was left, and holds while you read.
        seenSince = UserDefaults.standard.object(forKey: Self.lookedKey) as? Date
        shownAt = .now
        reload()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        markLooked()
    }

    /// Today was on screen and is being left (another tab, or the app going away).
    @objc private func markLooked() {
        guard shownAt != nil, view.window != nil else { return }
        UserDefaults.standard.set(Date.now, forKey: Self.lookedKey)
    }

    private func sinceYouLooked(_ glance: Glance, days: [Day], today: String) {
        let latest = Array(glance.visits.filter { $0.bestPhoto != nil }.reversed())
        guard !latest.isEmpty else { return }
        let fresh = seenSince.map { since in latest.filter { $0.at > since } } ?? []
        let shown: [Visit]
        if let since = seenSince, !fresh.isEmpty {
            add(SectionTitle("\(Words.count(fresh.count, "new visit").capitalizedFirst) since \(Words.since(since))"), top: 30)
            shown = Array(fresh.prefix(Self.carouselSize))
        } else {
            // Nothing new: the latest, without a headline that says so.
            add(SectionTitle("Latest visitors"), top: 30)
            shown = Array(latest.prefix(seenSince == nil ? Self.carouselSize : 8))
        }
        add(Carousel(visits: shown, from: self) { [weak self] visit, source in
            self?.open(visit: visit, among: shown, from: source)
        }, inset: false, top: 12)
        var rows: [UIView] = []
        // The latest day's reel: today's once it has one, else yesterday's.
        if let reelDay = days.prefix(2).first(where: { $0.reel != nil }), let reel = reelDay.reel {
            let name = reelDay.day == today ? "Today" : Words.dayName(reelDay.day)
            var row: DoorRow!
            row = DoorRow("\(name) in \(Int(reel.length.rounded())) seconds",
                          detail: "The best moment of each of \(Words.count(reel.clips, "visit"))",
                          symbol: "play.circle.fill", chevron: false) { [weak self] in
                guard let self else { return }
                ReelButton.play(reel, from: self, out: row)
            }
            rows.append(row)
        }
        let day = Yard.calendar.day(of: shown[0].at)
        rows.append(DoorRow("All of \(day == today ? "today" : Words.dayName(day).lowercased())",
                            detail: "In the journal", symbol: "book") { [weak self] in self?.openJournal(at: day) })
        add(Panel.rows(rows), top: 12)
    }

    // MARK: - What to expect

    private func expect(_ glance: Glance, night: Bool) {
        let hours = glance.hours()
        guard hours.usual.contains(where: { $0 > 0 }) else { return }
        add(SectionTitle("What to expect"), top: 30)
        let chart = DayChart(today: hours.today, usual: hours.usual, now: night ? nil : Yard.calendar.calendar.component(.hour, from: .now))
        let sentence: String
        if night || glance.todays.isEmpty, let first = glance.usuallyFirst() {
            // An average, so to the nearest five minutes: "around 8:40", not "8:38".
            let minutes = Int((Double(first.minutes) / 5).rounded()) * 5
            let when = Words.clockWithHalf.string(from: Yard.calendar.calendar.date(
                bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now)
            sentence = "\(Words.plural(first.bird.name).capitalizedFirst) usually come first, around \(when)."
        } else {
            let next = glance.comingUp()
            sentence = next.isEmpty ? "The rest of the day is usually quiet."
                : next.enumerated().map { i, item in
                    let who = Words.plural(item.bird.name)
                    let at = "around \(Words.hourName(item.hour))"
                    return i == 0 ? "\(who.capitalizedFirst) usually come \(at)" : "and \(who) \(at)"
                }.joined(separator: ", ") + "."
        }
        let label = UILabel(font: Style.subheadline)
        label.text = sentence
        add(Panel([label, chart], spacing: 14), top: 10)
    }

    // MARK: - Worth a look

    private func worthALook(_ glance: Glance) {
        let notable = glance.notable()
        guard !notable.isEmpty else { return }
        add(SectionTitle("Worth a look"), top: 30)
        func face(_ key: String?) -> FaceView {
            let face = FaceView(size: 40)
            face.show(bird: key)
            return face
        }
        let rows: [UIView] = notable.map { item in
            switch item {
            case .newBird(let bird):
                return DoorRow("New to the yard: \(bird.name)",
                               detail: "First seen \(Words.recently(bird.firstSeen)). The \(Words.ordinal(bird.yardNo ?? 0)) bird on the yard list.",
                               leading: face(bird.key)) { [weak self] in self?.open(bird: bird.key) }
            case .probable(let bird, let visit):
                return DoorRow("Probably a \(bird.name)",
                               detail: "\(Words.recently(visit.at).capitalizedFirst) at \(Words.clockWithHalf.string(from: visit.at)). On the yard list once there's a clear photo.",
                               leading: face(bird.key)) { [weak self] in self?.open(visit: visit) }
            case .back(let bird, let visit, let days):
                return DoorRow("The \(Words.shortName(bird.name)) is back",
                               detail: "After \(days) days away, \(Words.recently(visit.at)) at \(Words.clockWithHalf.string(from: visit.at)).",
                               leading: face(bird.key)) { [weak self] in self?.open(visit: visit) }
            case .corrected(let visit):
                return DoorRow("Your correction landed", detail: Words.plain(visit.caption ?? ""),
                               symbol: "checkmark.seal") { [weak self] in self?.open(visit: visit) }
            }
        }
        add(Panel.rows(rows), top: 10)
    }

    /// Down the page, inside the gutters unless it runs edge to edge (a row
    /// to swipe through).
    private func add(_ view: UIView, inset: Bool = true, top: CGFloat = 0) {
        let box = UIView()
        box.pin(view, insets: UIEdgeInsets(top: top, left: inset ? Style.gutter : 0, bottom: 0,
                                            right: inset ? Style.gutter : 0))
        stack.addArrangedSubview(box)
    }

    /// The story, with each paragraph's bird a link to the bird.
    private func storyView(_ story: Writing) -> UIView {
        let text = NSMutableAttributedString()
        if let dateline = story.dateline {
            text.append(NSAttributedString(string: dateline + " ", attributes: [
                .font: Style.italic(Style.prose), .foregroundColor: Style.soft]))
        }
        for (i, paragraph) in story.paragraphs.enumerated() {
            let part = NSMutableAttributedString(attributedString: Words.bolded(
                paragraph.text + (i < story.paragraphs.count - 1 ? "\n\n" : ""),
                font: Style.prose, lineHeight: Style.proseLeading))
            if let key = paragraph.bird, let link = URL(string: "backyard://bird/\(key)") {
                part.enumerateAttribute(.font, in: NSRange(location: 0, length: part.length)) { font, range, _ in
                    if let font = font as? UIFont, font.fontDescriptor.symbolicTraits.contains(.traitBold) {
                        part.addAttribute(.link, value: link, range: range)
                    }
                }
            }
            text.append(part)
        }
        let view = UITextView()
        view.attributedText = text
        view.isEditable = false
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.linkTextAttributes = [.foregroundColor: Style.accent]
        view.delegate = self
        view.adjustsFontForContentSizeCategory = true
        return view
    }

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        guard case .link(let url) = textItem.content, url.scheme == "backyard", url.host == "bird" else { return defaultAction }
        return UIAction { [weak self] _ in self?.open(bird: url.lastPathComponent) }
    }

    /// The bird a card is about: "Listen for the junco" is the Dark-eyed Junco.
    private func bird(for note: Wall.Note, in birds: [Bird]) -> Bird? {
        guard let word = note.label.split(separator: " ").last.map({ String($0).lowercased() }),
              note.label.lowercased().hasPrefix("listen for") else { return nil }
        return birds.first { Words.shortName($0.name) == word }
    }
}

/// Today's birds as faces in a row to swipe, each with its name and how
/// many times it came.
final class FaceRow: UIScrollView {
    init(_ birds: [(Bird, Int)], open: @escaping (String) -> Void) {
        super.init(frame: .zero)
        showsHorizontalScrollIndicator = false
        alwaysBounceHorizontal = true
        contentInset = UIEdgeInsets(top: 0, left: Style.gutter, bottom: 0, right: Style.gutter)
        translatesAutoresizingMaskIntoConstraints = false
        let row = UIStackView()
        row.spacing = 14
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            row.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
            heightAnchor.constraint(equalTo: row.heightAnchor),
        ])
        for (bird, count) in birds {
            let face = FaceView(size: 68)
            face.show(bird: bird.key)
            let name = UILabel(font: Style.weight(Style.footnote, .semibold), lines: 2)
            name.text = bird.name
            name.textAlignment = .center
            let times = UILabel(font: Style.footnote, color: Style.soft, lines: 1)
            times.text = count == 1 ? "Once" : "\(count) times"
            times.textAlignment = .center
            let cell = UIStackView(arrangedSubviews: [face, name, times])
            cell.axis = .vertical
            cell.alignment = .center
            cell.spacing = 4
            cell.setCustomSpacing(8, after: face)
            name.widthAnchor.constraint(equalToConstant: 80).isActive = true
            let tap = UITapGestureRecognizer()
            tap.addAction { open(bird.key) }
            cell.addGestureRecognizer(tap)
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = "\(bird.name), \(times.text ?? "")"
            cell.accessibilityTraits = .button
            row.addArrangedSubview(cell)
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// The seed as the board draws it: so many bars of three.
final class SeedGauge: UIView {
    private let level: Int, of: Int

    init(level: Int, of: Int) {
        self.level = level
        self.of = of
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = "Seed, \(level) of \(of)"
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: CGFloat(of) * 7 - 2, height: 11) }

    override func draw(_ rect: CGRect) {
        for i in 0..<of {
            let bar = CGRect(x: CGFloat(i) * 7, y: 0, width: 5, height: 11)
            let path = UIBezierPath(roundedRect: bar, cornerRadius: 1.5)
            (i < level ? (level == 1 ? Style.warn : Style.accent) : Style.fill).setFill()
            path.fill()
        }
    }
}

/// One of the board's cards: "Did you know", or "Listen for the junco"
/// with a button that plays its call, and a door to the bird.
final class NoteCard: Panel {
    init(note: Wall.Note, bird: Bird?, open: @escaping (String) -> Void) {
        super.init(spacing: 6)
        let label = UILabel(font: Style.headline)
        label.text = note.label
        label.accessibilityTraits = .header
        let text = UILabel(font: Style.prose)
        text.attributedText = Words.bolded(note.text, font: Style.prose, lineHeight: Style.proseLeading)
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(text)
        if let bird {
            var pills: [UIView] = []
            if let call = bird.call {
                let playing = CallPlayer.shared.playing == call.url
                pills.append(Pill(playing ? "Stop" : "Hear it", symbol: playing ? "stop.fill" : "waveform") {
                    CallPlayer.shared.toggle(call.url)
                })
            }
            pills.append(Pill(bird.name, symbol: "chevron.right") { open(bird.key) })
            stack.setCustomSpacing(14, after: text)
            stack.addArrangedSubview(PillRow(pills))
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Today against a usual day, hour by hour through the daylight: a usual
/// day as outlines, today as solid bars, and a tick under the hour it is now.
final class DayChart: UIView {
    private static let hours = 5...20
    private let today: [Int]
    private let usual: [Double]
    private let now: Int?

    init(today: [Int], usual: [Double], now: Int?) {
        self.today = today
        self.usual = usual
        self.now = now
        super.init(frame: .zero)
        backgroundColor = .clear
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 92).isActive = true
        isAccessibilityElement = true
        let busiest = Self.hours.max { usual[$0] < usual[$1] }
        accessibilityLabel = "\(Words.count(today.reduce(0, +), "visit")) today. A usual day is busiest around \(busiest.map(Words.hourName) ?? "midday")."
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        let chart = bounds.height - 34  // room for the hours and the key
        let top = max(Self.hours.map { max(Double(today[$0]), usual[$0]) }.max() ?? 1, 1)
        let slot = bounds.width / CGFloat(Self.hours.count)
        let small: [NSAttributedString.Key: Any] = [.font: Style.axis, .foregroundColor: Style.soft]
        for (i, hour) in Self.hours.enumerated() {
            let x = CGFloat(i) * slot
            let usualH = CGFloat(usual[hour] / top) * chart
            let todayH = CGFloat(Double(today[hour]) / top) * chart
            if usualH > 0 {
                let outline = UIBezierPath(roundedRect: CGRect(x: x + 2, y: chart - usualH, width: slot - 4, height: usualH),
                                           cornerRadius: 2)
                Style.soft.withAlphaComponent(0.55).setStroke()
                outline.lineWidth = 1
                outline.stroke()
            } else {
                Style.rule.setFill()
                UIBezierPath(rect: CGRect(x: x + 2, y: chart - 1, width: slot - 4, height: 1)).fill()
            }
            if todayH > 0 {
                Style.accent.setFill()
                UIBezierPath(roundedRect: CGRect(x: x + 4, y: chart - todayH, width: slot - 8, height: todayH),
                             cornerRadius: 1.5).fill()
            }
            if hour == now {
                Style.ink.setFill()
                UIBezierPath(roundedRect: CGRect(x: x + slot / 2 - 1.5, y: chart + 3, width: 3, height: 3), cornerRadius: 1.5).fill()
            }
            if let label = [6: "6a", 9: "9a", 12: "noon", 15: "3p", 18: "6p"][hour] {
                (label as NSString).draw(at: CGPoint(x: x + 2, y: chart + 7), withAttributes: small)
            }
        }
        // The key.
        let keyY = bounds.height - 12
        Style.accent.setFill()
        UIBezierPath(roundedRect: CGRect(x: 0, y: keyY + 2, width: 8, height: 8), cornerRadius: 1.5).fill()
        ("Today" as NSString).draw(at: CGPoint(x: 12, y: keyY), withAttributes: small)
        let outline = UIBezierPath(roundedRect: CGRect(x: 56.5, y: keyY + 2.5, width: 7, height: 7), cornerRadius: 1.5)
        Style.soft.setStroke()
        outline.stroke()
        ("A usual day" as NSString).draw(at: CGPoint(x: 68, y: keyY), withAttributes: small)
    }
}
