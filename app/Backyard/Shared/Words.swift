import UIKit
import YardModel

/// How the yard's words and times read: Claude's **bold** bird names, and
/// times in the feeder's time zone, wherever the phone is.
@MainActor
enum Words {
    /// "A **House Finch** came." with the name in the bold of `font`.
    static func bolded(_ text: String, font: UIFont, color: UIColor = Style.ink,
                       lineHeight: CGFloat = 1.25) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = lineHeight
        let out = NSMutableAttributedString()
        for (i, part) in text.components(separatedBy: "**").enumerated() {
            out.append(NSAttributedString(string: part, attributes: [
                .font: i % 2 == 1 ? Style.bold(font) : font, .foregroundColor: color,
                .paragraphStyle: paragraph]))
        }
        return out
    }

    static func plain(_ text: String) -> String { text.replacingOccurrences(of: "**", with: "") }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = Yard.calendar.timeZone
        f.dateFormat = format
        return f
    }

    static let clock = formatter("h:mm")
    static let clockWithHalf = formatter("h:mm a")
    static let hour = formatter("h a")
    /// 3 → "3rd".
    static func ordinal(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static let weekday = formatter("EEEE")
    static let monthDay = formatter("MMMM d")
    static let monthYear = formatter("MMMM yyyy")
    static let month = formatter("MMMM")
    static let longDate = formatter("EEEE, MMMM d")
    static let shortDay = formatter("EEE, MMM d")

    /// "Today", "Yesterday", or the weekday, for a local date.
    static func dayName(_ day: String, now: Date = .now) -> String {
        let today = Yard.calendar.day(of: now)
        if day == today { return "Today" }
        if let date = Yard.calendar.date(of: day), Yard.calendar.day(of: date.addingTimeInterval(86_400)) == today {
            return "Yesterday"
        }
        return Yard.calendar.date(of: day).map(weekday.string) ?? day
    }

    /// "today", "yesterday", "Saturday" within the week, else "Oct 2".
    static func recently(_ date: Date, now: Date = .now) -> String {
        let name = dayName(Yard.calendar.day(of: date), now: now)
        if name == "Today" || name == "Yesterday" { return name.lowercased() }
        return now.timeIntervalSince(date) < 6 * 86_400 ? name : formatter("MMM d").string(from: date)
    }

    /// The time a visit shows: the minute for a postcard, the hour for Bird
    /// Buddy's hourly count.
    static func time(of visit: Visit) -> String {
        visit.source == .report ? hour.string(from: visit.at) : clock.string(from: visit.at)
    }

    /// Who wrote it, in a few words.
    static func author(_ by: String?) -> String {
        switch by {
        case nil: return "Unknown"
        case "owner": return "You"
        case "bird-buddy": return "Bird Buddy"
        case let by? where by.hasPrefix("claude"): return "Claude"
        case let by?: return by
        }
    }

    /// "sure", "probably", "maybe", for a sighting's confidence.
    static func sureness(_ confidence: Confidence?) -> String? {
        switch confidence {
        case .high: return "sure"
        case .medium: return "probably"
        case .low: return "maybe"
        case .birdBuddy: return "Bird Buddy's guess"
        case nil: return nil
        }
    }

    /// "A" or "An" before a name.
    static func article(_ name: String) -> String { "AEIOU".contains(name.prefix(1)) ? "An" : "A" }

    /// "1 visit", "4 visits", "4 new visits".
    static func count(_ n: Int, _ thing: String) -> String { n == 1 ? "1 \(thing)" : "\(n) \(thing)s" }

    /// A bird's name for many of them: "House Finches", "Steller's Jays".
    static func plural(_ name: String) -> String {
        if name.hasSuffix("ch") || name.hasSuffix("sh") || name.hasSuffix("s") || name.hasSuffix("x") { return name + "es" }
        if name.hasSuffix("y"), let before = name.dropLast().last, !"aeiou".contains(before) { return name.dropLast() + "ies" }
        return name + "s"
    }

    /// The moment after "since": "8:12 PM" today, "yesterday", "Saturday".
    static func since(_ date: Date, now: Date = .now) -> String {
        let name = dayName(Yard.calendar.day(of: date), now: now)
        if name == "Today" { return clockWithHalf.string(from: date) }
        return name == "Yesterday" ? "yesterday" : name
    }

    /// "just now", "12 minutes ago", or the time.
    static func ago(_ date: Date, now: Date = .now) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return minutes == 1 ? "a minute ago" : "\(minutes) minutes ago" }
        return "at \(clockWithHalf.string(from: date))"
    }

    /// The first sentence of something Claude wrote, as plain words.
    static func firstSentence(_ text: String) -> String {
        let plain = plain(text)
        if let end = plain.range(of: ". ") { return String(plain[..<end.lowerBound]) + "." }
        return plain
    }

    /// "7 AM", "noon", for an hour of the day.
    static func hourName(_ hour: Int) -> String {
        hour == 0 ? "midnight" : hour == 12 ? "noon" : hour < 12 ? "\(hour) AM" : "\(hour - 12) PM"
    }

    /// What people call it in passing: "Dark-eyed Junco" is the junco.
    static func shortName(_ name: String) -> String {
        (name.split(separator: " ").last.map(String.init) ?? name).lowercased()
    }

    /// A visit as words to paste into a conversation with Claude: when and
    /// where, what was seen and how sure, and links to the photos.
    static func forClaude(_ visit: Visit, photos: [URL]) -> String {
        var lines = ["A visit to our backyard bird feeder (a Bird Buddy camera), "
                     + "\(longDate.string(from: visit.at)) at \(clockWithHalf.string(from: visit.at))."]
        if !visit.birds.isEmpty {
            lines.append("Identified from the photos: " + visit.birds.map { bird in
                [bird.name, sureness(bird.confidence).map { "(\($0))" }, bird.details.map { "— \($0)" }]
                    .compactMap { $0 }.joined(separator: " ")
            }.joined(separator: "; "))
        }
        if let caption = visit.caption { lines.append("Caption: " + plain(caption)) }
        if let notes = visit.notes { lines.append("Notes: " + plain(notes)) }
        if !photos.isEmpty { lines.append("Photos:\n" + photos.map(\.absoluteString).joined(separator: "\n")) }
        return lines.joined(separator: "\n\n")
    }
}
