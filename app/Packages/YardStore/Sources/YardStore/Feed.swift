import Foundation
import YardModel

/// The files of the collector's feed (collector/feed.py), as they arrive.
/// The store turns them into YardModel values.
enum Feed {
    struct Index: Decodable {
        var version: Int
        var generatedAt: Date
        /// Where media paths ("m/<id>/s.jpg") are found.
        var media: URL
        var place: String?
        var tz: String?
        var now: Feeder?
        var yardList: [String]
        var days: [Entry]
        var weeks: [Entry]
        var birds: [Entry]
        /// The board's readings, line and cards, for Today.
        var wall: Wall?
        /// Where the phone leaves its marks (collector/feed.py's INBOX).
        var inbox: Inbox?
        /// The birds likely this month that haven't come yet.
        var likely: Likely?

        enum CodingKeys: String, CodingKey {
            case version, generatedAt = "generated_at", media, place, tz, now,
                 yardList = "yard_list", days, weeks, birds, wall, inbox, likely
        }
    }

    struct Inbox: Codable {
        /// Read it here (public, under the feed's unguessable folder)...
        var get: URL
        /// ...and write it here (a signed address, renewed every run).
        var put: URL
    }

    /// The inbox file: every phone's marks and what each wants to be told,
    /// each phone replacing its own.
    struct Marks: Codable {
        var marks: [WireMark]
        var devices: [WireDevice]?
    }

    /// One phone's notifications (collector/notify.py's save_devices).
    struct WireDevice: Codable, Equatable {
        var device: String
        var token: String?
        var env: String
        var status: String
        var kinds: [String]
        var follow: [String]
    }

    struct WireMark: Codable, Equatable {
        var id: String
        var kind: String  // keep | correct
        var visit: String
        var media: String?
        var name: String?
        var at: Date
        var device: String?
    }

    struct Entry: Decodable {
        var key: String
        var hash: String
    }

    struct Day: Decodable {
        var day: String
        var note: Note?
        var best: [String]
        var visits: [Visit]
        var reel: Reel?
    }

    struct Note: Decodable {
        var text: String
        var by: String
        var writtenAt: Date?
        enum CodingKeys: String, CodingKey { case text, by, writtenAt = "written_at" }
    }

    struct Week: Decodable {
        var week: String
        var end: String
        var days: [String]
        var story: Story?
    }

    struct Story: Decodable {
        var dateline: String
        var by: String
        var writtenAt: Date?
        var versions: Int?
        var paragraphs: [Writing.Paragraph]
        enum CodingKeys: String, CodingKey {
            case dateline, by, writtenAt = "written_at", versions, paragraphs
        }
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
