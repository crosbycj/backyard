import Foundation
import YardModel

/// What Today works out about the yard at a moment: today against a usual
/// day, who usually comes next, who usually comes first, and what's worth a
/// look. Worked out from the visits with photos (Bird Buddy's hourly counts
/// are left out), so it's the same on every phone and needs no Claude.
public struct Glance: Sendable {
    public let now: Date
    public let calendar: YardCalendar
    /// Visits with photos, oldest first.
    public let visits: [Visit]
    private let birds: [String: Bird]

    public init(visits: [Visit], birds: [Bird], now: Date = .now, calendar: YardCalendar = YardCalendar()) {
        self.now = now
        self.calendar = calendar
        self.visits = visits.filter { $0.source != .report && $0.at <= now }.sorted { $0.at < $1.at }
        self.birds = Dictionary(birds.map { ($0.key, $0) }) { a, _ in a }
    }

    private var cal: Calendar { calendar.calendar }
    private func hour(_ date: Date) -> Int { cal.component(.hour, from: date) }
    private var today: String { calendar.day(of: now) }

    public func bird(_ key: String?) -> Bird? { key.flatMap { birds[$0] } }

    /// Today's visits, oldest first.
    public var todays: [Visit] { visits.filter { calendar.day(of: $0.at) == today } }

    /// Visits on the days before today, within `days`, by local day.
    private func pastDays(_ days: Int) -> [String: [Visit]] {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        return Dictionary(grouping: visits.filter { $0.at >= since && calendar.day(of: $0.at) != today }) {
            calendar.day(of: $0.at)
        }
    }

    /// Visits in each hour of the day: today's, and a usual day's (the
    /// average over the days before, within `days`, that had any).
    public func hours(days: Int = 14) -> (today: [Int], usual: [Double]) {
        var todayCounts = Array(repeating: 0, count: 24)
        for visit in todays { todayCounts[hour(visit.at)] += 1 }
        let past = pastDays(days)
        var usual = Array(repeating: 0.0, count: 24)
        for visit in past.values.joined() { usual[hour(visit.at)] += 1 }
        let n = Double(max(past.count, 1))
        return (todayCounts, usual.map { $0 / n })
    }

    /// Up to two birds that usually come in the next few hours, each with
    /// the hour it most often comes. Only birds seen at least twice then.
    public func comingUp(within span: Int = 3, days: Int = 14) -> [(bird: Bird, hour: Int)] {
        let from = hour(now), to = from + span
        var byBird: [String: [Int]] = [:]
        for visit in pastDays(days).values.joined() {
            let h = hour(visit.at)
            guard h >= from, h < to, let key = visit.bird?.bird else { continue }
            byBird[key, default: []].append(h)
        }
        return byBird.filter { $0.value.count >= 2 }
            .sorted { $0.value.count > $1.value.count }
            .prefix(2)
            .compactMap { key, hours in
                let mode = Dictionary(grouping: hours, by: { $0 }).max { $0.value.count < $1.value.count }!.key
                return bird(key).map { ($0, mode) }
            }
    }

    /// The bird that most often comes first in the morning, and its usual
    /// time (minutes after midnight), over the days before today.
    public func usuallyFirst(days: Int = 14) -> (bird: Bird, minutes: Int)? {
        let firsts = pastDays(days).values.compactMap { $0.min { $0.at < $1.at } }
        let byBird = Dictionary(grouping: firsts.filter { $0.bird?.bird != nil }) { $0.bird!.bird! }
        guard let (key, visits) = byBird.max(by: { $0.value.count < $1.value.count }),
              visits.count >= 2, let bird = bird(key) else { return nil }
        let minutes = visits.map { cal.component(.hour, from: $0.at) * 60 + cal.component(.minute, from: $0.at) }
        return (bird, minutes.reduce(0, +) / minutes.count)
    }

    /// Something in the last week that deserves a look.
    public enum Notable: Hashable, Sendable {
        /// A bird new to the yard list.
        case newBird(Bird)
        /// A bird Claude wasn't sure of, not on the yard list yet.
        case probable(Bird, Visit)
        /// A regular, back after days away.
        case back(Bird, Visit, days: Int)
        /// A visit you corrected, now rewritten.
        case corrected(Visit)
    }

    /// What's worth a look, the most notable first; at most `limit`.
    public func notable(within days: Int = 7, limit: Int = 3) -> [Notable] {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        var out: [Notable] = []
        for bird in birds.values.sorted(by: { $0.firstSeen > $1.firstSeen })
        where bird.yardNo != nil && bird.firstSeen >= since {
            out.append(.newBird(bird))
        }
        var unsure = Set<String>()
        for visit in visits.reversed() where visit.at >= since {
            guard let key = visit.bird?.bird, let bird = bird(key), bird.yardNo == nil,
                  visit.bird?.confidence == .medium || visit.bird?.confidence == .low,
                  unsure.insert(key).inserted else { continue }
            out.append(.probable(bird, visit))
        }
        for bird in birds.values where bird.photographed >= 5 {
            let seen = visits.filter { $0.bird?.bird == bird.key }
            guard seen.count >= 2, let last = seen.last, now.timeIntervalSince(last.at) < 36 * 3600 else { continue }
            let gap = Int(last.at.timeIntervalSince(seen[seen.count - 2].at) / 86_400)
            if gap >= 3 { out.append(.back(bird, last, days: gap)) }
        }
        for visit in visits.reversed() where visit.by == "owner" {
            if let written = visit.writtenAt, now.timeIntervalSince(written) < 2 * 86_400 {
                out.append(.corrected(visit))
            }
        }
        return Array(out.prefix(limit))
    }
}
