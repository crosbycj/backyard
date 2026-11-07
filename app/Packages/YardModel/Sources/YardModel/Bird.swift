import Foundation

/// One kind of bird that's come to the yard: its names, its call, Claude's
/// cards about it, and when it was first and last seen.
public struct Bird: Codable, Hashable, Identifiable, Sendable {
    public var key: String
    public var name: String
    public var scientific: String?
    public var firstSeen: Date
    public var lastSeen: Date
    /// Its place on the yard list (birds Claude is sure of, by first photo).
    public var yardNo: Int?
    /// How many visits had a photo of it, not counting Bird Buddy's hourly counts.
    public var photographed: Int
    /// Bird Buddy's illustration.
    public var icon: URL?
    public var call: Call?
    public var cards: [Card]
    /// Its page in Cornell's All About Birds.
    public var guide: URL?
    /// Its best photos, by Claude's score, as media ids.
    public var best: [String]
    /// Its readable page in this yard, for a link (a path under the feed's address).
    public var page: String?

    public var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, name, scientific, firstSeen = "first_seen", lastSeen = "last_seen",
             yardNo = "yard_no", photographed, icon, call, cards, guide, best, page
    }

    public struct Call: Codable, Hashable, Sendable {
        public var url: URL
        public var by: String?
    }

    public struct Card: Codable, Hashable, Sendable {
        public var label: String
        public var text: String
        public var link: URL?
    }
}

/// The birds likely at the feeder this month that haven't come yet:
/// Claude's list for the season (collector/likely.py), for Birds to show as
/// empty circles until they come.
public struct Likely: Codable, Hashable, Sendable {
    /// "2026-10".
    public var month: String
    public var birds: [Hope]

    public struct Hope: Codable, Hashable, Sendable {
        public var name: String
        public var scientific: String?
        /// "common", "regular" or "occasional", at a local feeder this month.
        public var chance: String
        /// What to look or listen for, in a sentence.
        public var note: String
        /// Its page in Cornell's All About Birds.
        public var guide: URL?
    }
}
