import Foundation

/// Claude's words for a span of time: tonight's note for a day, or the
/// story as it stood at the end of a week. A lens opens with its writing.
public struct Writing: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case dayNote, story }

    public var kind: Kind
    /// The span it's about, as local dates ("2026-10-26").
    public var start: String
    public var end: String
    /// "Monday, October 26." for a story.
    public var dateline: String?
    /// One for a day note; one per bird for a story, each with **bold** names.
    public var paragraphs: [Paragraph]
    public var by: String
    public var writtenAt: Date?
    /// How many times the story was revised that week.
    public var versions: Int?

    public init(kind: Kind, start: String, end: String, dateline: String? = nil,
                paragraphs: [Paragraph], by: String, writtenAt: Date?, versions: Int? = nil) {
        self.kind = kind; self.start = start; self.end = end; self.dateline = dateline
        self.paragraphs = paragraphs; self.by = by; self.writtenAt = writtenAt; self.versions = versions
    }

    public var text: String { paragraphs.map(\.text).joined(separator: "\n\n") }

    public struct Paragraph: Codable, Hashable, Sendable {
        public var text: String
        /// The bird it's about, if any.
        public var bird: String?

        public init(text: String, bird: String? = nil) { self.text = text; self.bird = bird }
    }
}
