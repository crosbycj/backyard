import Foundation

/// One time something came to the feeder: a Bird Buddy postcard with photos
/// and a video, an hour of Bird Buddy's report (a count, no photos), or
/// photos imported by hand. Its words are Claude's, unless you corrected
/// them.
public struct Visit: Codable, Hashable, Identifiable, Sendable {
    public enum Source: String, Codable, Sendable { case postcard, report, `import` }

    public var id: String
    public var at: Date
    public var source: Source
    /// The feed's sentence, with the bird's name in **bold**.
    public var caption: String?
    /// What was happening, a few sentences.
    public var notes: String?
    /// Who wrote it: a model id, "claude (session)", "owner" or "bird-buddy".
    public var by: String?
    public var writtenAt: Date?
    public var confidence: Confidence?
    public var birds: [Sighting]
    public var media: [Media]
    /// Claude's pick of the visit's photos.
    public var best: String?
    /// Claude's print score for the best photo, 1 (a back, a blur) to 5.
    public var score: Int?
    /// Where the bird is in the best photo, as shares of its width and height.
    public var box: Box?
    /// For an hour of Bird Buddy's report: how many visits it counted.
    public var reported: Int?
    /// Its catalogue number in the archive, given once when it came in. Only
    /// a visit with photos has one.
    public var number: Int?

    enum CodingKeys: String, CodingKey {
        case id, at, source, caption, notes, by, writtenAt = "written_at", confidence, birds,
             media, best, score, box, reported, number, page
    }

    /// Its readable page, for a link to share or give to Claude (a path
    /// under the feed's address, like the media).
    public var page: String?

    /// Its photos (and Claude's stills from the video) in the order they
    /// were taken, so they run forward through the visit's minute.
    public var photos: [Media] {
        media.filter { $0.kind != .video }.sorted { (moment(of: $0) ?? 0) < (moment(of: $1) ?? 0) }
    }
    public var video: Media? { media.first { $0.kind == .video } }

    /// Seconds into the visit's video at which a photo was taken: a still
    /// says so in its id ("<visit>:frame:52.5"), a photo by its time. Nil
    /// without a video or a time.
    public func moment(of photo: Media) -> Double? {
        if photo.kind == .frame, let s = photo.id.split(separator: ":").last.flatMap({ Double($0) }) { return s }
        guard let start = video?.at, let at = photo.at else { return nil }
        return at.timeIntervalSince(start)
    }
    public var bestPhoto: Media? { photos.first { $0.id == best } ?? photos.first }
    /// The first bird named: the one the caption is about.
    public var bird: Sighting? { birds.first { $0.bird != nil } ?? birds.first }
}

public enum Confidence: String, Codable, Sendable { case high, medium, low, birdBuddy = "bird-buddy" }

/// One kind of animal in a visit, as the current identification saw it.
public struct Sighting: Codable, Hashable, Sendable {
    public var name: String
    public var scientific: String?
    /// The bird's key ("house-finch"), or nil for a squirrel.
    public var bird: String?
    public var count: Int?
    public var confidence: Confidence?
    /// Sex, age, plumage, behavior.
    public var details: String?
}

/// A photo, a still Claude chose from the video, or the video.
public struct Media: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case photo, frame, video }

    public var id: String
    public var kind: Kind
    public var w: Int?
    public var h: Int?
    /// Paths under the feed's media address.
    public var small: String?
    public var large: String?
    public var video: String?
    /// When it was taken (a video: when it began).
    public var at: Date?

    /// Width over height; Bird Buddy's photos are 3:4 portrait.
    public var aspect: Double {
        guard let w, let h, h > 0 else { return 3.0 / 4.0 }
        return Double(w) / Double(h)
    }
}

public struct Box: Codable, Hashable, Sendable {
    public var left, top, right, bottom: Double
}

/// A day's reel: each visit's best few seconds, one after another (made by
/// the collector, collector/reel.py).
public struct Reel: Codable, Hashable, Sendable {
    /// A path under the feed's media address.
    public var video: String
    /// Seconds.
    public var length: Double
    /// How many visits are in it.
    public var clips: Int
}
