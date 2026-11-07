import Foundation
import YardModel

/// The yard at a glance, for the widget: the latest bird with a photo, the
/// seed, and how many came today. Read straight from the feed (the widget
/// has no store of its own), so it's as fresh as the collector's last run.
public struct Glimpse: Sendable {
    public var visit: Visit?
    /// Its best photo, full size.
    public var photo: URL?
    /// The seed gauge: `seed` of `seedOf` bars, and what it means ("probably out").
    public var seed: Int?
    public var seedOf: Int?
    public var seedUntil: String?
    /// Visits today, where the day's file is today's.
    public var today: Int?

    public init(visit: Visit? = nil, photo: URL? = nil, seed: Int? = nil, seedOf: Int? = nil,
                seedUntil: String? = nil, today: Int? = nil) {
        self.visit = visit; self.photo = photo; self.seed = seed; self.seedOf = seedOf
        self.seedUntil = seedUntil; self.today = today
    }

    /// From the feed at `feed` (its index.json): the newest days first, back
    /// as far as the last visit with a photo (three days at most).
    public static func fetch(from feed: URL, session: URLSession = .shared) async throws -> Glimpse {
        func get(_ url: URL) async throws -> Data {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return data
        }
        let index = try Feed.decoder.decode(Feed.Index.self, from: try await get(feed))
        var glimpse = Glimpse(seed: index.wall?.now?.seed, seedOf: index.wall?.now?.seedOf,
                              seedUntil: index.wall?.now?.seedUntil)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = index.tz.flatMap(TimeZone.init(identifier:)) ?? .current
        let todayKey = formatter.string(from: .now)
        for entry in index.days.sorted(by: { $0.key > $1.key }).prefix(3) {
            guard let url = URL(string: "days/\(entry.key).json", relativeTo: feed) else { continue }
            let day = try Feed.decoder.decode(Feed.Day.self, from: try await get(url))
            let visits = day.visits.filter { $0.source != .report }
            if entry.key == todayKey { glimpse.today = visits.count }
            if let latest = visits.filter({ $0.bestPhoto?.large != nil }).max(by: { $0.at < $1.at }) {
                glimpse.visit = latest
                glimpse.photo = latest.bestPhoto?.large.flatMap { URL(string: $0, relativeTo: index.media)?.absoluteURL }
                break
            }
        }
        if glimpse.today == nil, index.days.contains(where: { $0.key == todayKey }) == false { glimpse.today = 0 }
        return glimpse
    }
}
