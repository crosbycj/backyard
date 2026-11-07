import Foundation

/// What a screen shows: a span of time at a zoom, maybe narrowed to one
/// bird or to what was kept. The Journal, a Bird and Kept are all lenses.
public struct Lens: Hashable, Sendable {
    public enum Zoom: Int, CaseIterable, Sendable { case day, week, month }

    public var zoom: Zoom
    /// The bird it's narrowed to, by key.
    public var bird: String?
    /// Only what was kept.
    public var kept: Bool

    public init(zoom: Zoom = .day, bird: String? = nil, kept: Bool = false) {
        self.zoom = zoom; self.bird = bird; self.kept = kept
    }

    public static let journal = Lens()
}

/// The yard's calendar: days are local dates where the feeder is, and weeks
/// run Monday to Sunday, as the feed files them.
public struct YardCalendar: Sendable {
    public let timeZone: TimeZone
    public let calendar: Calendar

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        calendar.locale = Locale(identifier: "en_US")
        self.calendar = calendar
    }

    /// "2026-10-26" for a moment.
    public func day(of date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Noon on a local date, for formatting it.
    public func date(of day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    public func monday(of day: String) -> String? {
        guard let date = date(of: day),
              let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { return nil }
        return self.day(of: start.addingTimeInterval(12 * 3600))
    }
}
