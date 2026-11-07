import Foundation

/// What the board on the wall knows right now, sent with the feed so Today
/// says the same: the readings, the day's line, and the cards it dealt.
public struct Wall: Codable, Hashable, Sendable {
    public var now: Readings?
    /// Tonight's note, today in numbers, or the day ahead, with **bold** names.
    public var line: String?
    public var notes: [Note]

    public struct Readings: Codable, Hashable, Sendable {
        /// "53°, cloudy".
        public var weather: String?
        /// "6:01" by day; "7:45" by night.
        public var sunset: String?
        public var sunrise: String?
        /// The seed as Claude last saw the tray: `seed` of `seedOf` bars (0
        /// is out), in words ("a few left", "probably out"), and when it was
        /// seen ("4:12 PM", "Tuesday").
        public var seed: Int?
        public var seedOf: Int?
        public var seedUntil: String?
        public var seedSeen: String?
        /// Something wrong with the feeder, in a sentence.
        public var alert: String?

        enum CodingKeys: String, CodingKey {
            case weather, sunset, sunrise, seed, seedOf = "seed_of", seedUntil = "seed_until",
                 seedSeen = "seed_seen", alert
        }
    }

    /// A card: "Did you know", or "Listen for the junco" with its call.
    public struct Note: Codable, Hashable, Sendable {
        public var label: String
        public var text: String
        public var link: URL?
    }
}

/// Something a person said about a visit in the app: its bird is really
/// this one. The phone keeps it, sends it with the marks, and the collector
/// has Claude rewrite the visit around it.
public struct Correction: Codable, Hashable, Sendable {
    public var id: String
    public var visit: String
    /// The bird's name as they gave it ("Steller's Jay").
    public var name: String
    public var at: Date

    public init(id: String = UUID().uuidString, visit: String, name: String, at: Date = .now) {
        self.id = id; self.visit = visit; self.name = name; self.at = at
    }
}
