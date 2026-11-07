import UIKit
import YardModel
import YardStore

/// A rounded container for what belongs together, the way Health and
/// Settings group things: a card on the page, never loose words.
class Panel: UIView {
    let stack = UIStackView()

    init(_ views: [UIView] = [], spacing: CGFloat = 10,
         padding: UIEdgeInsets = UIEdgeInsets(top: Style.inset, left: Style.inset, bottom: Style.inset, right: Style.inset)) {
        super.init(frame: .zero)
        backgroundColor = Style.card
        layer.cornerRadius = Style.radius
        layer.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = spacing
        pin(stack, insets: padding)
        views.forEach(stack.addArrangedSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Rows one above another, a hairline between them (from the rows' text,
    /// as in Settings). Each row brings its own height.
    static func rows(_ rows: [UIView]) -> Panel {
        let panel = Panel(spacing: 0, padding: UIEdgeInsets(top: 0, left: Style.inset, bottom: 0, right: Style.inset))
        for (i, row) in rows.enumerated() {
            if i > 0 {
                let line = UIView()
                line.backgroundColor = Style.rule
                line.translatesAutoresizingMaskIntoConstraints = false
                let holder = UIView()
                holder.pin(line, insets: UIEdgeInsets(top: 0, left: (row as? Inset)?.textInset ?? 0, bottom: 0, right: 0))
                line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
                panel.stack.addArrangedSubview(holder)
            }
            panel.stack.addArrangedSubview(row)
        }
        return panel
    }
}

/// A row whose words start in from its edge (past a face or a symbol),
/// where the hairline above it starts too.
protocol Inset { var textInset: CGFloat { get } }

/// How sure Claude is, as a small capsule: a meter of three dots and a
/// word. Sure fills all three in moss; probably two; maybe one.
final class ConfidenceBadge: UIView {
    init(_ confidence: Confidence?) {
        super.init(frame: .zero)
        let (word, filled): (String, Int) = switch confidence {
        case .high: ("Sure", 3)
        case .medium: ("Probably", 2)
        case .low: ("Maybe", 1)
        case .birdBuddy: ("Bird Buddy's guess", 0)
        case nil: ("Not judged", 0)
        }
        let sure = confidence == .high
        let color = sure ? Style.accent : Style.soft
        backgroundColor = sure ? Style.accent.withAlphaComponent(0.13) : Style.fill
        layer.cornerRadius = 11
        layer.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        let dots = UIStackView(arrangedSubviews: (0..<3).map { i in
            let dot = UIView()
            dot.backgroundColor = i < filled ? color : color.withAlphaComponent(0.25)
            dot.layer.cornerRadius = 3
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 6), dot.heightAnchor.constraint(equalToConstant: 6)])
            return dot
        })
        dots.spacing = 2.5
        dots.isHidden = filled == 0
        let label = UILabel(font: Style.weight(Style.footnote, .semibold), color: color, lines: 1)
        label.text = word
        let row = UIStackView(arrangedSubviews: [dots, label])
        row.spacing = 6
        row.alignment = .center
        pin(row, insets: UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 9))
        isAccessibilityElement = true
        accessibilityLabel = word
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// One bird that came in a visit: its face, its name, how sure Claude is
/// (and how many, if more than one), then what Claude noticed, in full.
/// A door to the bird, when it's one of the yard's.
final class SightingRow: UIControl, Inset {
    private let action: () -> Void
    let textInset: CGFloat = 56 + 14

    init(_ sighting: Sighting, face: FaceView, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let name = UILabel(font: Style.headline, lines: 2)
        name.text = sighting.name
        var tags: [UIView] = [ConfidenceBadge(sighting.confidence)]
        if let count = sighting.count, count > 1 {
            let many = UILabel(font: Style.weight(Style.footnote, .semibold), color: Style.soft, lines: 1)
            many.text = "\(count) at once"
            tags.append(many)
        }
        let tagRow = UIStackView(arrangedSubviews: tags + [UIView()])
        tagRow.spacing = 8
        tagRow.alignment = .center
        let details = UILabel(font: Style.subheadline, color: Style.soft)
        details.text = sighting.details
        details.isHidden = (sighting.details ?? "").isEmpty
        let words = UIStackView(arrangedSubviews: [name, tagRow, details])
        words.axis = .vertical
        words.spacing = 6
        words.setCustomSpacing(8, after: tagRow)
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = Style.soft.withAlphaComponent(0.6)
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.isHidden = sighting.bird == nil
        // The face at the top, beside the name; the chevron in the middle.
        let faceColumn = UIStackView(arrangedSubviews: [face, UIView()])
        faceColumn.axis = .vertical
        let chevronColumn = UIView()
        chevronColumn.addSubview(chevron)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chevron.centerYAnchor.constraint(equalTo: chevronColumn.centerYAnchor),
            chevron.leadingAnchor.constraint(equalTo: chevronColumn.leadingAnchor),
            chevron.trailingAnchor.constraint(equalTo: chevronColumn.trailingAnchor),
        ])
        chevronColumn.isHidden = chevron.isHidden
        let row = UIStackView(arrangedSubviews: [faceColumn, words, chevronColumn])
        row.spacing = 14
        row.alignment = .fill
        row.isUserInteractionEnabled = false
        pin(row, insets: UIEdgeInsets(top: 14, left: 0, bottom: 14, right: 0))
        addAction(UIAction { [weak self] _ in self?.action() }, for: .touchUpInside)
        isEnabled = sighting.bird != nil
        isAccessibilityElement = true
        accessibilityLabel = [sighting.name, Words.sureness(sighting.confidence), sighting.details].compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = sighting.bird == nil ? .staticText : .button
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { UIView.animate(withDuration: 0.12) { self.alpha = self.isHighlighted ? 0.45 : 1 } }
    }
}

/// The ways to act on something, as equal tiles in a row: a symbol over a
/// word, the way Contacts offers message, call, mail.
final class ActionTiles: UIStackView {
    struct Action {
        var title: String
        var symbol: String
        var run: () -> Void
    }

    init(_ actions: [Action]) {
        super.init(frame: .zero)
        axis = .horizontal
        distribution = .fillEqually
        spacing = 8
        translatesAutoresizingMaskIntoConstraints = false
        for action in actions { addArrangedSubview(Tile(action)) }
    }

    required init(coder: NSCoder) { fatalError() }

    private final class Tile: UIControl {
        private let run: () -> Void

        init(_ action: Action) {
            run = action.run
            super.init(frame: .zero)
            backgroundColor = Style.card
            layer.cornerRadius = 16
            layer.cornerCurve = .continuous
            let icon = UIImageView(image: UIImage(systemName: action.symbol))
            icon.tintColor = Style.accent
            icon.contentMode = .center
            icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body, scale: .large)
            let label = UILabel(font: Style.weight(Style.footnote, .medium), color: Style.accent, lines: 1)
            label.text = action.title
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.8
            let stack = UIStackView(arrangedSubviews: [icon, label])
            stack.axis = .vertical
            stack.spacing = 4
            stack.alignment = .center
            stack.isUserInteractionEnabled = false
            pin(stack, insets: UIEdgeInsets(top: 12, left: 4, bottom: 10, right: 4))
            heightAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
            addAction(UIAction { [weak self] _ in self?.run() }, for: .touchUpInside)
            isAccessibilityElement = true
            accessibilityLabel = action.title
            accessibilityTraits = .button
        }

        required init?(coder: NSCoder) { fatalError() }

        override var isHighlighted: Bool {
            didSet { UIView.animate(withDuration: 0.12) { self.alpha = self.isHighlighted ? 0.5 : 1 } }
        }
    }
}

/// A bird's face: a photo cropped close around it, in a circle. Its own
/// visit's when there is one, or the bird's best clear photo (Faces).
final class FaceView: UIView {
    let photo = PhotoView()
    private let placeholder = UIImageView(image: UIImage(systemName: "bird.fill"))

    init(size: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = Style.fill
        layer.cornerRadius = size / 2
        clipsToBounds = true
        placeholder.tintColor = Style.soft
        placeholder.contentMode = .center
        placeholder.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: size * 0.36)
        pin(placeholder)
        photo.faceZoom = 0.85
        photo.backgroundColor = .clear
        pin(photo)
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size)])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The bird's best face.
    func show(bird key: String?) {
        show(visit: key.flatMap(Faces.visit))
    }

    /// The bird in this visit.
    func show(visit: Visit?) {
        placeholder.isHidden = visit?.box != nil
        photo.isHidden = visit?.box == nil
        photo.show(Yard.store.url(visit?.box == nil ? nil : visit?.bestPhoto?.large), box: visit?.box)
    }
}

/// Which photo is each bird's face: a clear one where it's the bird Claude
/// is sure of, with a good score, and big enough in the frame to crop.
@MainActor
enum Faces {
    private static var picked: [String: Visit?] = [:]
    private static var asOf: Date?

    static func visit(for key: String) -> Visit? {
        // A new sync may have a better photo.
        let generated = try? Yard.store.generatedAt()
        if generated != asOf { picked = [:]; asOf = generated }
        if let hit = picked[key] { return hit }
        let visits = ((try? Yard.store.visits(Lens(bird: key))) ?? []).filter {
            $0.source != .report && $0.box != nil && $0.bestPhoto?.large != nil && $0.bird?.bird == key
        }
        let face = visits.max { rank($0) < rank($1) }
        picked[key] = face
        return face
    }

    private static func rank(_ visit: Visit) -> (Int, Int, Double) {
        let sure = (visit.bird?.confidence ?? visit.confidence) == .high ? 1 : 0
        let area = visit.box.map { ($0.right - $0.left) * ($0.bottom - $0.top) } ?? 0
        // A bird that fills a fifth of the photo is plenty; past that, bigger isn't better.
        return (sure, visit.score ?? 0, min(area, 0.2))
    }
}

/// A heading over part of a page, in the serif like every title: "Worth a
/// look". With room above it, so a page reads in parts.
final class SectionTitle: UILabel {
    init(_ text: String) {
        super.init(frame: .zero)
        font = Style.title
        adjustsFontForContentSizeCategory = true
        textColor = Style.ink
        numberOfLines = 0
        self.text = text
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityTraits = .header
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// A small fact in a tile: "Seed" over "Probably out", "Sunset" over "6:01".
final class FactTile: UIView {
    init(_ label: String, value: String, detail: String? = nil, accessory: UIView? = nil, warn: Bool = false) {
        super.init(frame: .zero)
        backgroundColor = Style.card
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        let name = UILabel(font: Style.footnote, color: Style.soft, lines: 1)
        name.text = label
        let fact = UILabel(font: Style.headline, color: warn ? Style.warn : Style.ink, lines: 2)
        fact.text = value
        fact.adjustsFontSizeToFitWidth = true
        fact.minimumScaleFactor = 0.8
        let top = UIStackView(arrangedSubviews: [name] + (accessory.map { [$0] } ?? []))
        top.spacing = 6
        top.alignment = .center
        let under = UILabel(font: Style.footnote, color: Style.soft, lines: 1)
        under.text = detail
        under.isHidden = detail == nil
        let stack = UIStackView(arrangedSubviews: [top, fact, under])
        stack.axis = .vertical
        stack.spacing = 4
        stack.alignment = .leading
        // From the top, so a row of tiles reads across on one line.
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
        ])
        isAccessibilityElement = true
        accessibilityLabel = [label, value, detail].compactMap { $0 }.joined(separator: ", ")
    }

    required init?(coder: NSCoder) { fatalError() }
}
