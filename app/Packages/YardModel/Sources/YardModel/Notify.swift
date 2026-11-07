import Foundation

/// What this phone wants to be told, as the collector reads it from the
/// inbox (collector/notify.py): a switch for each kind, and the birds it
/// follows. How loud each kind is stays the collector's and iOS's.
public struct NotifySettings: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Every photographed visit, quietly, a bird's repeats folded together.
        case visit
        /// A photo Claude scored its best, or a bird back after weeks away.
        case good
        /// A bird new to the yard list.
        case new
        /// The birds in `follow`.
        case follow
        /// Tonight's note, once it's written.
        case note
        /// The week's story, Sunday evening.
        case story
        /// The seed's probably out.
        case seed
        /// A visit Claude called a maybe, asked as a question.
        case decide
        /// The feeder offline or low, Bird Buddy unreachable, or the feed gone stale.
        case broken
    }

    public var kinds: Set<Kind>
    /// The birds followed, by key ("stellers-jay").
    public var follow: Set<String>

    /// Before anyone has chosen: the ones that are about the yard, not the machinery.
    public static let start = NotifySettings(kinds: [.good, .new, .follow, .note, .story, .seed],
                                             follow: [])

    public init(kinds: Set<Kind>, follow: Set<String>) {
        self.kinds = kinds; self.follow = follow
    }
}

/// Where Apple delivers this phone's notifications.
public struct PushAddress: Codable, Hashable, Sendable {
    /// The device token, in hex.
    public var token: String?
    /// "production" for TestFlight and the App Store, "sandbox" for Xcode's builds.
    public var env: String
    /// What the person allowed: authorized, provisional, denied, ephemeral, notDetermined.
    public var status: String

    public init(token: String?, env: String, status: String) {
        self.token = token; self.env = env; self.status = status
    }
}
