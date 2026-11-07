import ImageIO
import SwiftUI
import WidgetKit
import YardModel
import YardStore

/// The yard on the home screen: the latest bird's best photo, cropped
/// around the bird, with its name and when; beside it, on the wider one,
/// what Claude saw and the seed. On the Lock Screen, the same in words.
/// It reads the feed itself every half hour; opening the app refreshes it
/// at once. Tapping opens that visit.
@main
struct BackyardWidgets: WidgetBundle {
    var body: some Widget { YardWidget() }
}

struct YardWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "yard", provider: Provider()) { entry in
            FamilyView(entry: entry)
        }
        .configurationDisplayName("The yard")
        .description("The latest bird at the feeder, and the seed.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

struct FamilyView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    var body: some View { YardView(entry: entry, family: family) }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        Task { completion(await load(context)) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        Task {
            let entry = await load(context)
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
        }
    }

    private func load(_ context: Context) async -> Entry {
        guard let string = Bundle.main.object(forInfoDictionaryKey: "YardFeedURL") as? String,
              let feed = URL(string: string),
              let glimpse = try? await Glimpse.fetch(from: feed) else { return Entry(date: .now) }
        var photo: UIImage?
        if let url = glimpse.photo, let (data, _) = try? await URLSession.shared.data(from: url) {
            // Square, around the bird, no bigger than the widget needs.
            let side = max(context.displaySize.width, context.displaySize.height) * 3
            photo = Entry.square(data, focus: glimpse.visit?.box, pixels: min(side, 1000))
        }
        return Entry(date: .now, glimpse: glimpse, photo: photo)
    }
}

