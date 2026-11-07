import Foundation

/// Something kept: a visit or one photo, marked on this phone.
public struct Mark: Codable, Hashable, Sendable {
    public var visit: String
    public var media: String?
    public var at: Date

    public init(visit: String, media: String? = nil, at: Date = .now) {
        self.visit = visit; self.media = media; self.at = at
    }
}

/// The feeder as the collector last read it.
public struct Feeder: Codable, Hashable, Sendable {
    public var at: Date
    /// READY_TO_STREAM, OFFLINE, DEEP_SLEEP...
    public var state: String?
    /// HIGH, MEDIUM or LOW: all Bird Buddy says about the seed.
    public var food: String?
    public var battery: Int?
}
