import ImageIO
import SwiftUI
import WidgetKit
import YardModel
import YardStore

/// What the widget draws, shared with the app so a debug launch can draw it
/// too (`-widgets yes`).
struct Entry: TimelineEntry {
    var date: Date
    var glimpse: Glimpse?
    var photo: UIImage?

    /// The photo downsampled and cut to a square around the bird.
    static func square(_ data: Data, focus box: Box?, pixels: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: pixels * 1.4]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height), side = min(w, h)
        let fx = CGFloat(box.map { ($0.left + $0.right) / 2 } ?? 0.5)
        let fy = CGFloat(box.map { ($0.top + $0.bottom) / 2 } ?? 0.5)
        let x = min(max(w * fx - side / 2, 0), w - side)
        let y = min(max(h * fy - side / 2, 0), h - side)
        return image.cropping(to: CGRect(x: x, y: y, width: side, height: side)).map(UIImage.init(cgImage:))
    }
}

// MARK: - Views

private enum Look {
    // The app's dark stone and ink (Style); rust is only for the seed running out.
    static let paper = Color(red: 0x10 / 255, green: 0x12 / 255, blue: 0x0F / 255)
    static let ink = Color(red: 0xE8 / 255, green: 0xEA / 255, blue: 0xE1 / 255)
    static let soft = Color(red: 0x9C / 255, green: 0xA2 / 255, blue: 0x94 / 255)
    static let accent = Color(red: 0xE0 / 255, green: 0x8A / 255, blue: 0x5E / 255)
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

struct YardView: View {
    let entry: Entry
    let family: WidgetFamily

    private var visit: Visit? { entry.glimpse?.visit }
    private var name: String { visit?.bird?.name ?? (visit == nil ? "The yard" : "A visitor") }
    private var link: URL? { visit.flatMap { URL(string: "backyard://visit/\($0.id)") } }

    /// "8:30 AM", or "Yesterday, 3:12 PM", or "Saturday".
    private var when: String {
        guard let at = visit?.at else { return "No birds yet" }
        let calendar = Calendar.current
        let time = at.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(at) { return time }
        if calendar.isDateInYesterday(at) { return "Yesterday, \(time)" }
        return at.formatted(.dateTime.weekday(.wide))
    }

    /// "Seed: a few left", "Seed: probably out", or nothing while there's plenty.
    private var seed: String? {
        guard let g = entry.glimpse, let level = g.seed, level <= 1 else { return nil }
        return "Seed: \(g.seedUntil ?? (level == 0 ? "out" : "low"))"
    }

    var body: some View {
        content.widgetURL(link)
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline:
            Text(visit == nil ? "The yard" : "\(name), \(when)")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.headline).widgetAccentable()
                Text(when).font(.caption)
                if let seed { Text(seed).font(.caption) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(.clear, for: .widget)
        case .systemMedium:
            HStack(spacing: 0) {
                photo.frame(width: 170)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(Look.serif(19, .semibold)).foregroundStyle(Look.ink).lineLimit(2)
                    Text(when).font(.caption).foregroundStyle(Look.soft)
                    if let caption = visit?.caption {
                        Text(plain(caption)).font(Look.serif(13)).foregroundStyle(Look.ink.opacity(0.85))
                            .lineLimit(3).padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                    footer
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .containerBackground(Look.paper, for: .widget)
        case .systemLarge:
            VStack(spacing: 0) {
                photo.frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(name).font(Look.serif(20, .semibold)).foregroundStyle(Look.ink).lineLimit(1)
                        Spacer()
                        Text(when).font(.caption).foregroundStyle(Look.soft)
                    }
                    if let caption = visit?.caption {
                        Text(plain(caption)).font(Look.serif(14)).foregroundStyle(Look.ink.opacity(0.85)).lineLimit(2)
                    }
                    footer.padding(.top, 2)
                }
                .padding(14)
            }
            .containerBackground(Look.paper, for: .widget)
        default:
            // Small: the photo, with the name over its foot.
            ZStack(alignment: .bottomLeading) {
                photo
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(Look.serif(16, .semibold)).lineLimit(2)
                    Text(when).font(.caption2).opacity(0.85)
                    if let seed { Text(seed).font(.caption2.weight(.semibold)).foregroundStyle(Look.accent) }
                }
                .foregroundStyle(.white)
                .padding(12)
            }
            .containerBackground(Look.paper, for: .widget)
        }
    }

    @ViewBuilder private var photo: some View {
        if let image = entry.photo {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity).clipped()
        } else {
            Rectangle().fill(Look.soft.opacity(0.25))
                .overlay(Image(systemName: "bird").font(.title).foregroundStyle(Look.soft))
        }
    }

    /// "1 today · Seed low", whatever's known.
    @ViewBuilder private var footer: some View {
        let parts = [entry.glimpse?.today.map { $0 == 1 ? "1 visit today" : "\($0) visits today" }, seed].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · ")).font(.caption2).foregroundStyle(seed == nil ? Look.soft : Look.accent)
        }
    }

    /// Claude's caption without its **bold** marks.
    private func plain(_ text: String) -> String { text.replacingOccurrences(of: "**", with: "") }
}
