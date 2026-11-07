import UIKit
import YardModel
import YardStore

/// "Yesterday" in the serif, then "October 27 · 9 visits" under it.
final class DayHeaderView: UICollectionReusableView {
    private let name = UILabel(font: Style.title, lines: 1)
    private let detail = UILabel(font: Style.footnote, color: Style.soft, lines: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        name.accessibilityTraits = .header
        let stack = UIStackView(arrangedSubviews: [name, detail])
        stack.axis = .vertical
        stack.spacing = 1
        pin(stack, insets: UIEdgeInsets(top: 22, left: 4, bottom: 8, right: 4))
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ day: String, visits: [Visit]) {
        name.text = Words.dayName(day)
        let date = Yard.calendar.date(of: day)
        // A weekday's name already says which day; "Today" and "Yesterday" need the date.
        let when = date.map { Words.dayName(day) == Words.weekday.string(from: $0) ? Words.monthDay.string(from: $0)
            : Words.longDate.string(from: $0) } ?? day
        let postcards = visits.filter { $0.source != .report }.count
        detail.text = postcards == 0 ? when : "\(when) · \(Words.count(postcards, "visit"))"
    }
}

/// The base of every row in a day's group: the card's color, pressed a
/// shade darker.
class DayRowCell: UICollectionViewListCell {
    override func updateConfiguration(using state: UICellConfigurationState) {
        var background = UIBackgroundConfiguration.listCell().updated(for: state)
        background.backgroundColor = state.isHighlighted || state.isSelected ? Style.fill : Style.card
        backgroundConfiguration = background
    }
}

/// Claude's note for the day, in the serif, with its birds in bold.
final class DayNoteCell: DayRowCell {
    private let text = UILabel(font: Style.prose)
    private let byline = UILabel(font: Style.footnote, color: Style.soft)

    override init(frame: CGRect) {
        super.init(frame: frame)
        let stack = UIStackView(arrangedSubviews: [text, byline])
        stack.axis = .vertical
        stack.spacing = 6
        contentView.pin(stack, insets: UIEdgeInsets(top: 14, left: Style.inset, bottom: 14, right: Style.inset))
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ writing: Writing) {
        text.attributedText = Words.bolded(writing.text, font: Style.prose, lineHeight: Style.proseLeading)
        let when = writing.writtenAt.map { " at " + Words.clockWithHalf.string(from: $0) } ?? ""
        byline.text = "Tonight's note, by \(Words.author(writing.by))\(when)"
    }
}

/// "▶ The day in 35 seconds", a row that plays the reel.
final class ReelCell: DayRowCell {
    private var reel: Reel?
    private weak var screen: UIViewController?
    private let icon = UIImageView(image: UIImage(systemName: "play.circle.fill"))
    private let title = UILabel(font: Style.headline, color: Style.accent, lines: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.tintColor = Style.accent
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title2)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [icon, title])
        row.spacing = 10
        row.alignment = .center
        contentView.pin(row, insets: UIEdgeInsets(top: 12, left: Style.inset, bottom: 12, right: Style.inset))
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ reel: Reel, from screen: UIViewController) {
        self.reel = reel
        self.screen = screen
        title.text = "The day in \(Int(reel.length.rounded())) seconds"
    }

    func play() {
        guard let reel, let screen else { return }
        ReelButton.play(reel, from: screen, out: icon)
    }
}

/// One visit: its photo, when, and Claude's sentence. Bird Buddy's hourly
/// counts are quieter: the hour, in grey, no photo.
final class VisitCell: DayRowCell {
    let photo = PhotoView()
    private let time = UILabel(font: Style.footnote, color: Style.soft, lines: 1)
    private let caption = UILabel(font: Style.prose, lines: 3)
    private var photoWidth: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        photo.layer.cornerRadius = 10
        photo.layer.cornerCurve = .continuous
        photo.translatesAutoresizingMaskIntoConstraints = false
        let words = UIStackView(arrangedSubviews: [time, caption])
        words.axis = .vertical
        words.spacing = 2
        words.translatesAutoresizingMaskIntoConstraints = false
        [photo, words].forEach(contentView.addSubview)
        photoWidth = photo.widthAnchor.constraint(equalToConstant: 60)
        NSLayoutConstraint.activate([
            photo.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Style.inset),
            photo.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            photoWidth,
            photo.heightAnchor.constraint(equalToConstant: 60),
            photo.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),
            words.leadingAnchor.constraint(equalTo: photo.trailingAnchor, constant: 12),
            words.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Style.inset),
            words.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            words.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),
            contentView.bottomAnchor.constraint(equalTo: words.bottomAnchor, constant: 12).withPriority(.defaultHigh),
        ])
        separatorLayoutGuide.leadingAnchor.constraint(equalTo: words.leadingAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ visit: Visit) {
        let report = visit.source == .report
        time.text = report ? "\(Words.time(of: visit)) · Bird Buddy's count" : Words.clockWithHalf.string(from: visit.at)
        let text = visit.caption ?? visit.bird.map { "A **\($0.name)** came." } ?? "Something came to the feeder."
        let font = report ? Style.subheadline : Style.prose
        caption.attributedText = Words.bolded(text, font: font, color: report ? Style.soft : Style.ink, lineHeight: 1.08)
        let best = visit.bestPhoto
        photo.isHidden = best == nil
        photoWidth.constant = best == nil ? 0 : 60
        photo.show(Yard.store.url(best?.small), box: visit.box)
    }
}

/// A month as a calendar of faces: each day the yard had visitors shows
/// the bird that came most, from that day's own photo. A day opens the
/// journal there. It lives in the journal's `MonthShade`.
final class MonthView: UIView {
    var onDay: ((String) -> Void)?
    var onMonth: ((Int) -> Void)?
    private let title = UILabel(font: Style.headline, lines: 1)
    private let summary = UILabel(font: Style.footnote, color: Style.soft, lines: 1)
    private let back = UIButton(type: .system)
    private let forward = UIButton(type: .system)
    private let grid = UIStackView()
    private var faces: [String: DayFace] = [:]

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for (button, symbol, step) in [(back, "chevron.left", -1), (forward, "chevron.right", 1)] {
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .headline))
            config.baseForegroundColor = Style.accent
            button.configuration = config
            button.addAction(UIAction { [weak self] _ in self?.onMonth?(step) }, for: .primaryActionTriggered)
        }
        back.accessibilityLabel = "Previous month"
        forward.accessibilityLabel = "Next month"
        let names = UIStackView(arrangedSubviews: [title, summary])
        names.axis = .vertical
        names.spacing = 1
        let top = UIStackView(arrangedSubviews: [names, back, forward])
        top.alignment = .center
        grid.axis = .vertical
        grid.spacing = 6
        let stack = UIStackView(arrangedSubviews: [top, grid])
        stack.axis = .vertical
        stack.spacing = 12
        pin(stack)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `month` is any day in it; `days` are the journal's, by key.
    func show(month: Date, days: [String: Day], canBack: Bool, canNext: Bool) {
        let calendar = Yard.calendar.calendar
        title.text = Words.monthYear.string(from: month)
        back.isEnabled = canBack
        forward.isEnabled = canNext
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        faces = [:]
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return }

        let symbols = calendar.veryShortWeekdaySymbols
        let heads = UIStackView(arrangedSubviews: symbols.indices.map { i in
            let label = UILabel(font: Style.weight(Style.footnote, .semibold), color: Style.soft, lines: 1)
            label.text = symbols[(i + calendar.firstWeekday - 1) % 7]
            label.textAlignment = .center
            return label
        })
        heads.distribution = .fillEqually
        grid.addArrangedSubview(heads)

        let today = Yard.calendar.day(of: .now)
        let first = interval.start.addingTimeInterval(12 * 3600)
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        var cells: [UIView] = (0..<lead).map { _ in UIView() }
        var visits = 0, kinds = Set<String>()
        for n in 0..<count {
            let date = calendar.date(byAdding: .day, value: n, to: first)!
            let key = Yard.calendar.day(of: date)
            let shown = (days[key]?.visits ?? []).filter { $0.source != .report }
            visits += shown.count
            kinds.formUnion(shown.compactMap { $0.bird?.bird })
            let face = DayFace(number: n + 1, visits: shown, today: key == today) { [weak self] in
                if !shown.isEmpty { self?.onDay?(key) }
            }
            faces[key] = face
            cells.append(face)
        }
        while cells.count % 7 != 0 { cells.append(UIView()) }
        for week in stride(from: 0, to: cells.count, by: 7) {
            let row = UIStackView(arrangedSubviews: Array(cells[week..<week + 7]))
            row.distribution = .fillEqually
            row.spacing = 4
            grid.addArrangedSubview(row)
        }
        summary.text = visits == 0 ? "No visits" : kinds.isEmpty ? Words.count(visits, "visit")
            : "\(Words.count(visits, "visit")) · \(Words.count(kinds.count, "kind")) of bird"
    }

    /// Set the day you're reading apart, or none.
    func mark(_ day: String?) {
        for (key, face) in faces { face.isMarked = key == day }
    }

    /// The row a day's week is in, in this view's own coordinates.
    func week(of day: String) -> CGRect? {
        guard let row = faces[day]?.superview else { return nil }
        layoutIfNeeded()
        return row.convert(row.bounds, to: self)
    }
}

/// One day in the month: its number, over the face of the bird that came
/// most (its own best photo that day).
private final class DayFace: UIControl {
    private let tap: () -> Void

    init(number: Int, visits: [Visit], today: Bool, tap: @escaping () -> Void) {
        self.tap = tap
        super.init(frame: .zero)
        let face = FaceView(size: 40)
        var counts: [String: Int] = [:]
        for visit in visits { if let key = visit.bird?.bird { counts[key, default: 0] += 1 } }
        let top = counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        let pick = visits.filter { $0.bird?.bird == top && $0.box != nil }.max { ($0.score ?? 0) < ($1.score ?? 0) }
        if let pick { face.show(visit: pick) }
        face.isHidden = visits.isEmpty
        if today {
            face.layer.borderColor = Style.accent.cgColor
            face.layer.borderWidth = 2
        }
        // Every day keeps the same height: a day with no visitors puts its
        // number where the face would be.
        let label = UILabel(font: today ? Style.weight(Style.footnote, .bold) : Style.footnote,
                            color: today ? Style.accent : visits.isEmpty ? Style.soft : Style.ink, lines: 1)
        label.text = visits.isEmpty ? " " : "\(number)"
        label.textAlignment = .center
        let holder = UIView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(face)
        let empty = UILabel(font: Style.footnote, color: Style.soft, lines: 1)
        empty.text = "\(number)"
        empty.isHidden = !visits.isEmpty
        holder.addSubview(empty)
        NSLayoutConstraint.activate([
            face.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            face.topAnchor.constraint(equalTo: holder.topAnchor),
            face.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        let stack = UIStackView(arrangedSubviews: [holder, label])
        stack.axis = .vertical
        stack.spacing = 2
        stack.isUserInteractionEnabled = false
        pin(stack)
        addAction(UIAction { [weak self] _ in self?.tap() }, for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityLabel = visits.isEmpty ? "\(number), no visits" : "\(number), \(Words.count(visits.count, "visit"))"
        accessibilityTraits = visits.isEmpty ? .staticText : .button
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { UIView.animate(withDuration: 0.12) { self.alpha = self.isHighlighted ? 0.5 : 1 } }
    }

    /// The day you're reading, on a control's ground.
    var isMarked = false {
        didSet {
            backgroundColor = isMarked ? Style.fill : nil
            layer.cornerRadius = 12
            layer.cornerCurve = .continuous
        }
    }
}

/// The top of a bird's page: its best photo, where it stands, when it
/// comes, what to do with it, and Claude's cards.
final class BirdHeaderCell: UICollectionViewCell {
    var onOpen: ((Visit, UIView) -> Void)?
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.spacing = 12
        contentView.pin(stack, insets: UIEdgeInsets(top: 4, left: Style.gutter, bottom: 0, right: Style.gutter))
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ bird: Bird, visits: [Visit], from screen: UIViewController) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Its best photos, the ones where it's the main bird first (a junco
        // at the edge of a chickadee's photo isn't the junco's best).
        let picked = bird.best.compactMap { id in visits.first { $0.best == id } }
        let best = picked.filter { $0.bird?.bird == bird.key } + picked.filter { $0.bird?.bird != bird.key }

        // Its scientific name, in italic as names of species are set, under
        // the bar's title with room to breathe.
        if let scientific = bird.scientific {
            let latin = UILabel(font: Style.italic(Style.prose), color: Style.soft)
            latin.text = scientific
            stack.addArrangedSubview(latin)
            stack.setCustomSpacing(14, after: latin)
        }

        // The best of them, big: it opens its visit.
        if let hero = best.first ?? Faces.visit(for: bird.key) {
            let photo = PhotoView()
            photo.layer.cornerRadius = Style.radius
            photo.layer.cornerCurve = .continuous
            photo.translatesAutoresizingMaskIntoConstraints = false
            photo.heightAnchor.constraint(equalTo: photo.widthAnchor, multiplier: 0.75).isActive = true
            photo.show(Yard.store.url(hero.bestPhoto?.large), box: hero.box)
            photo.isUserInteractionEnabled = true
            let tap = UITapGestureRecognizer()
            tap.addAction { [weak self, weak photo] in if let photo { self?.onOpen?(hero, photo) } }
            photo.addGestureRecognizer(tap)
            photo.isAccessibilityElement = true
            photo.accessibilityLabel = "The best photo of the \(bird.name)"
            photo.accessibilityTraits = .button
            stack.addArrangedSubview(photo)
        }

        // Where it stands, as three facts, and when in the day it comes.
        var counts = Array(repeating: 0, count: 24)
        for visit in visits { counts[Yard.calendar.calendar.component(.hour, from: visit.at)] += 1 }
        let peak = counts.indices.max { counts[$0] < counts[$1] }
        let facts = UIStackView(arrangedSubviews: [
            stat(bird.yardNo.map(Words.ordinal) ?? "Not yet", bird.yardNo == nil ? "sure of it" : "on the yard list"),
            stat("\(bird.photographed)", bird.photographed == 1 ? "visit" : "visits"),
            stat(peak.map(Words.hourName) ?? "–", "busiest"),
        ])
        facts.distribution = .fillEqually
        let seen = UILabel(font: Style.footnote, color: Style.soft)
        seen.text = "First seen \(Words.recently(bird.firstSeen)), last seen \(Words.recently(bird.lastSeen))."
        stack.addArrangedSubview(Panel([facts, HoursStrip(counts: counts), seen], spacing: 14))
        stack.addArrangedSubview(birdActions(bird, from: screen))

        if best.count > 1 {
            stack.setCustomSpacing(28, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(SectionTitle("Best photos"))
            stack.addArrangedSubview(VisitStrip(visits: Array(best.dropFirst())) { [weak self] visit, source in
                self?.onOpen?(visit, source)
            })
        }
        if !bird.cards.isEmpty {
            stack.setCustomSpacing(28, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(SectionTitle("About it"))
            for card in bird.cards {
                let label = UILabel(font: Style.headline)
                label.text = card.label
                let text = UILabel(font: Style.prose)
                text.attributedText = Words.bolded(card.text, font: Style.prose, lineHeight: Style.proseLeading)
                stack.addArrangedSubview(Panel([label, text], spacing: 6))
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> UIView {
        let big = UILabel(font: Style.title, lines: 1)
        big.text = value
        big.adjustsFontSizeToFitWidth = true
        big.minimumScaleFactor = 0.7
        let small = UILabel(font: Style.footnote, color: Style.soft, lines: 1)
        small.text = label
        let stack = UIStackView(arrangedSubviews: [big, small])
        stack.axis = .vertical
        stack.spacing = 0
        stack.isAccessibilityElement = true
        stack.accessibilityLabel = "\(value) \(label)"
        return stack
    }
}

/// When a bird comes: one bar per hour of the day, as tall as its visits.
final class HoursStrip: UIView {
    private let counts: [Int]

    init(counts: [Int]) {
        self.counts = counts
        super.init(frame: .zero)
        backgroundColor = .clear
        heightAnchor.constraint(equalToConstant: 56).isActive = true
        isAccessibilityElement = true
        let peak = counts.indices.max { counts[$0] < counts[$1] }
        accessibilityLabel = peak.map { "Comes most around \(Words.hourName($0))" }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        let top = counts.max() ?? 0
        let width = bounds.width / 24
        let chart = bounds.height - 16
        let labels: [Int: String] = [0: "12a", 6: "6a", 12: "noon", 18: "6p"]
        for hour in 0..<24 {
            let x = CGFloat(hour) * width
            let h = top == 0 ? 0 : max(CGFloat(counts[hour]) / CGFloat(top) * chart, counts[hour] > 0 ? 3 : 2)
            let bar = UIBezierPath(roundedRect: CGRect(x: x + 1.5, y: chart - h, width: width - 3, height: h), cornerRadius: 2)
            (counts[hour] > 0 ? Style.accent : Style.fill).setFill()
            bar.fill()
            if let label = labels[hour] {
                (label as NSString).draw(at: CGPoint(x: x + 1.5, y: chart + 3), withAttributes: [
                    .font: Style.axis, .foregroundColor: Style.soft])
            }
        }
    }
}
