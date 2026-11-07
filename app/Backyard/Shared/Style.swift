import UIKit

/// The yard's look: warm stone and moss, Claude's words in a serif, the
/// system's own shapes for everything you touch. Light and dark.
enum Style {
    /// The page behind everything: warm stone, a little green.
    static let paper = dynamic(light: 0xF0EFE7, dark: 0x10120F)
    /// The paper as a screen's ground, with a fine grain in it, felt more
    /// than seen.
    static let page = UIColor { $0.userInterfaceStyle == .dark ? darkPage : lightPage }
    private static let lightPage = grain(on: 0xF0EFE7, by: 5)
    private static let darkPage = grain(on: 0x10120F, by: 3)
    /// What sits on the page: a container, a tile, a card.
    static let card = dynamic(light: 0xFCFBF6, dark: 0x1C1F1A)
    /// A control inside a card: a button's ground, an empty bar.
    static let fill = dynamic(light: 0xE6E6DB, dark: 0x2B2F27)
    static let ink = dynamic(light: 0x1E211C, dark: 0xE8EAE1)
    static let soft = dynamic(light: 0x676D60, dark: 0x9CA294)
    static let rule = dynamic(light: 0xDADBCF, dark: 0x30342C)
    /// Moss: what you can touch, and today.
    static let accent = dynamic(light: 0x4B6B3A, dark: 0x9DBE84)
    /// The feeder's rust, only for something wrong: the seed's out, it's offline.
    static let warn = dynamic(light: 0xB0532A, dark: 0xE08A5E)

    static let gutter: CGFloat = 16
    /// A container's corners, and its inside margin.
    static let radius: CGFloat = 22
    static let inset: CGFloat = 16

    // The type ramp, each one of the system's text styles so it follows the
    // reader's text size. Newsreader for titles, names and what Claude
    // wrote; SF for everything you touch and scan, its figures lined up.

    /// The bars' large titles: "Today", "Steller's Jay". (Set in styleBars.)
    static var largeTitle: UIFont { serif(34, .bold, relativeTo: .largeTitle) }
    /// A part of a page, a visit's caption, a bird's name on a card.
    static var title: UIFont { serif(22, .semibold, relativeTo: .title2) }
    /// What Claude wrote.
    static var prose: UIFont { serif(17, relativeTo: .body) }
    /// A row's or a tile's name.
    static var headline: UIFont { sans(17, .semibold, relativeTo: .headline) }
    /// The line under a name, in soft.
    static var subheadline: UIFont { sans(15, relativeTo: .subheadline) }
    /// Times, counts, who wrote it. Figures line up.
    static var footnote: UIFont { sans(13, relativeTo: .footnote).withFeatures(monospacedDigits: true) }
    /// Only a chart's axes.
    static var axis: UIFont { sans(11, relativeTo: .caption2).withFeatures(monospacedDigits: true) }

    /// Claude's words, with their line height.
    static let proseLeading: CGFloat = 1.22

    static func styleBars() {
        let bar = UINavigationBarAppearance()
        bar.configureWithDefaultBackground()
        let clear = UINavigationBarAppearance()
        clear.configureWithTransparentBackground()
        if #available(iOS 26.0, *) {
            // On iOS 26 the bar is glass over the page, with the scroll edge
            // effect under it: no solid bar.
            bar.configureWithTransparentBackground()
        }
        for appearance in [bar, clear] {
            appearance.titleTextAttributes = [.font: serif(17, .semibold, relativeTo: .headline), .foregroundColor: ink]
            appearance.largeTitleTextAttributes = [.font: largeTitle, .foregroundColor: ink]
        }
        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().compactAppearance = bar
        UINavigationBar.appearance().scrollEdgeAppearance = clear
    }

    /// Newsreader, scaled with the reader's text size.
    static func serif(_ size: CGFloat, _ weight: UIFont.Weight = .regular, italic: Bool = false,
                      relativeTo style: UIFont.TextStyle = .body) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(for: newsreader(size, wght: wght(weight), italic: italic))
    }

    static func sans(_ size: CGFloat, _ weight: UIFont.Weight = .regular,
                     relativeTo style: UIFont.TextStyle = .body) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight))
    }

    static func italic(_ font: UIFont) -> UIFont {
        if let serif = newsreaderParts(font) { return newsreader(font.pointSize, wght: serif.wght, italic: true, opsz: serif.opsz) }
        return font.fontDescriptor.withSymbolicTraits(.traitItalic).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
    }

    static func bold(_ font: UIFont) -> UIFont {
        if let serif = newsreaderParts(font) {
            return newsreader(font.pointSize, wght: max(serif.wght, 680), italic: serif.italic, opsz: serif.opsz)
        }
        return font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitBold)).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
    }

    /// The same style at another weight: a footnote in semibold.
    static func weight(_ font: UIFont, _ weight: UIFont.Weight) -> UIFont {
        if let serif = newsreaderParts(font) { return newsreader(font.pointSize, wght: wght(weight), italic: serif.italic, opsz: serif.opsz) }
        let descriptor = font.fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    // Newsreader is one variable font (and its italic) with two axes: its
    // weight, and its optical size, which follows the size it's set at
    // (sturdier for prose, finer for titles).
    private static let variation = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
    private static let wghtAxis = NSNumber(value: 0x7767_6874)  // 'wght'
    private static let opszAxis = NSNumber(value: 0x6F70_737A)  // 'opsz'

    private static func newsreader(_ size: CGFloat, wght: Double, italic: Bool, opsz: Double? = nil) -> UIFont {
        let name = italic ? "Newsreader16pt-Italic" : "Newsreader16pt-Regular"
        let axes = [wghtAxis: NSNumber(value: wght), opszAxis: NSNumber(value: opsz ?? min(max(Double(size), 6), 72))]
        let font = UIFont(descriptor: UIFontDescriptor(name: name, size: size).addingAttributes([variation: axes]), size: size)
        guard font.fontName.hasPrefix("Newsreader") else {
            let base = UIFont.systemFont(ofSize: size, weight: wght >= 650 ? .bold : wght >= 550 ? .semibold : .regular)
            return base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
        }
        return font
    }

    /// A Newsreader font's weight, optical size and slant, to make another like it.
    private static func newsreaderParts(_ font: UIFont) -> (wght: Double, opsz: Double, italic: Bool)? {
        guard font.fontName.hasPrefix("Newsreader") else { return nil }
        let axes = font.fontDescriptor.fontAttributes[variation] as? [NSNumber: NSNumber]
        return (axes?[wghtAxis]?.doubleValue ?? 400, axes?[opszAxis]?.doubleValue ?? Double(font.pointSize),
                font.fontName.contains("Italic"))
    }

    private static func wght(_ weight: UIFont.Weight) -> Double {
        switch weight {
        case ..<UIFont.Weight.light: 200
        case ..<UIFont.Weight.regular: 300
        case ..<UIFont.Weight.medium: 400
        case ..<UIFont.Weight.semibold: 500
        case ..<UIFont.Weight.bold: 600
        case ..<UIFont.Weight.heavy: 700
        default: 800
        }
    }

    /// A color with noise in it, one speck per screen pixel: each pixel a
    /// few levels lighter or darker, more often near than far. The same
    /// tile every time, so the page doesn't shimmer between launches.
    private static func grain(on hex: UInt32, by levels: Int) -> UIColor {
        let side = 256
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        var seed: UInt32 = 0x5EED
        func roll() -> Int {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Int(seed >> 24) % (levels + 1)
        }
        let base = [Int(hex >> 16 & 0xFF), Int(hex >> 8 & 0xFF), Int(hex & 0xFF)]
        for i in 0..<side * side {
            let shift = roll() - roll()
            for c in 0..<3 { pixels[i * 4 + c] = UInt8(clamping: base[c] + shift) }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return color(hex) }
        return UIColor(patternImage: UIImage(cgImage: image, scale: UIScreen.main.scale, orientation: .up))
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? color(dark) : color(light) }
    }

    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension UILabel {
    convenience init(font: UIFont, color: UIColor = Style.ink, lines: Int = 0) {
        self.init()
        self.font = font
        textColor = color
        numberOfLines = lines
        adjustsFontForContentSizeCategory = true
        translatesAutoresizingMaskIntoConstraints = false
    }
}

extension UIView {
    func pin(_ view: UIView, insets: UIEdgeInsets = .zero) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }
}

extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

extension UIFont {
    func withFeatures(monospacedDigits: Bool) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.featureSettings: [[
            UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
            UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector]]])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

extension String {
    /// "A **Finch**" → "a **Finch**", for the middle of a sentence.
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
    /// "4 visits" → "4 visits", "juncos" → "Juncos", for the start of one.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
