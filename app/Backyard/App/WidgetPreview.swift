#if DEBUG
import SwiftUI
import WidgetKit
import YardStore

/// `-widgets yes`: draws the widget in each size from the live feed, to
/// widget-<size>.png in the app's temporary folder, for checking by eye
/// without putting it on a home screen.
@MainActor
enum WidgetPreview {
    static func render() async {
        guard let string = Bundle.main.object(forInfoDictionaryKey: "YardFeedURL") as? String,
              let feed = URL(string: string), let glimpse = try? await Glimpse.fetch(from: feed) else {
            print("widgets: no feed"); return
        }
        var photo: UIImage?
        if let url = glimpse.photo, let (data, _) = try? await URLSession.shared.data(from: url) {
            photo = Entry.square(data, focus: glimpse.visit?.box, pixels: 1000)
        }
        let entry = Entry(date: .now, glimpse: glimpse, photo: photo)
        let sizes: [(String, WidgetFamily, CGSize)] = [
            ("small", .systemSmall, CGSize(width: 170, height: 170)),
            ("medium", .systemMedium, CGSize(width: 364, height: 170)),
            ("large", .systemLarge, CGSize(width: 364, height: 382)),
            ("rectangular", .accessoryRectangular, CGSize(width: 172, height: 76)),
            ("inline", .accessoryInline, CGSize(width: 300, height: 22)),
        ]
        for (name, family, size) in sizes {
            let home = name == "small" || name == "medium" || name == "large"
            let view = YardView(entry: entry, family: family)
                .frame(width: size.width, height: size.height)
                .foregroundStyle(home ? Color.primary : .white)
                .background(home ? Color(red: 0.08, green: 0.08, blue: 0.075) : Color(white: 0.3))
                .clipShape(RoundedRectangle(cornerRadius: home ? 22 : 8, style: .continuous))
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(name).png")
            try? renderer.uiImage?.pngData()?.write(to: url)
        }
        print("widgets: drawn to \(FileManager.default.temporaryDirectory.path)")
    }
}
#endif
