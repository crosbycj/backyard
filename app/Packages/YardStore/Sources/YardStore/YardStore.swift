import Foundation
import GRDB
import YardModel

/// The phone's own copy of the yard: a SQLite file, filled from the
/// collector's feed, that every screen reads through a lens.
///
/// Visits, days, weeks and birds are kept as the feed sent them (JSON),
/// with the columns a lens needs beside them. Marks (what was kept, and
/// birds corrected) are the phone's own: they never come from the feed, and
/// they go back to the collector through the inbox (sendMarks).
public final class YardStore: @unchecked Sendable {
    public static let didChange = Notification.Name("YardStoreDidChange")

    let db: DatabaseQueue
    public let feedURL: URL
    public let calendar: YardCalendar
    /// Each lens's days, decoded once until the store changes.
    private var memo: [Lens: [Day]] = [:]
    private let lock = NSLock()

    public init(path: URL?, feedURL: URL, calendar: YardCalendar = YardCalendar()) throws {
        db = try path.map { try DatabaseQueue(path: $0.path) } ?? DatabaseQueue()
        self.feedURL = feedURL
        self.calendar = calendar
        try Self.migrator.migrate(db)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            // The hash of every feed file we hold, to fetch only what changed.
            try db.create(table: "file") { t in
                t.primaryKey("path", .text)
                t.column("hash", .text).notNull()
            }
            try db.create(table: "visit") { t in
                t.primaryKey("id", .text)
                t.column("day", .text).notNull().indexed()
                t.column("at", .double).notNull()
                t.column("json", .blob).notNull()
            }
            try db.create(table: "visitBird") { t in
                t.column("visit", .text).notNull().references("visit", onDelete: .cascade)
                t.column("bird", .text).notNull().indexed()
                t.primaryKey(["visit", "bird"])
            }
            // A day without its visits: tonight's note and its best photos.
            try db.create(table: "day") { t in
                t.primaryKey("day", .text)
                t.column("json", .blob).notNull()
            }
            try db.create(table: "week") { t in
                t.primaryKey("start", .text)
                t.column("json", .blob).notNull()
            }
            try db.create(table: "bird") { t in
                t.primaryKey("key", .text)
                t.column("json", .blob).notNull()
            }
            try db.create(table: "meta") { t in
                t.primaryKey("key", .text)
                t.column("json", .blob).notNull()
            }
            try db.create(table: "mark") { t in
                t.column("visit", .text).notNull()
                t.column("media", .text).notNull().defaults(to: "")
                t.column("at", .double).notNull()
                t.primaryKey(["visit", "media"])
            }
        }
        m.registerMigration("v2") { db in
            // A bird corrected on this phone. It stays until the feed's visit
            // says the same (the collector applied it), and is sent every time.
            try db.create(table: "correction") { t in
                t.primaryKey("id", .text)
                t.column("visit", .text).notNull().indexed()
                t.column("name", .text).notNull()
                t.column("at", .double).notNull()
            }
        }
        return m
    }

    /// Something changed: forget what was decoded, and tell the screens.
    func changed() {
        lock.withLock { memo = [:] }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: - Reading

    /// The days a lens shows, newest first, each with its writing, its best
    /// photos and its visits (oldest first, as the day went).
    public func days(_ lens: Lens) throws -> [Day] {
        if let hit = lock.withLock({ memo[lens] }) { return hit }
        let days = try readDays(lens)
        lock.withLock { memo[lens] = days }
        return days
    }

    private func readDays(_ lens: Lens) throws -> [Day] {
        try db.read { db in
            var sql = "SELECT visit.day, visit.json FROM visit"
            var args: [DatabaseValueConvertible] = []
            if let bird = lens.bird {
                sql += " JOIN visitBird ON visitBird.visit = visit.id AND visitBird.bird = ?"
                args.append(bird)
            }
            if lens.kept {
                sql += " WHERE visit.id IN (SELECT visit FROM mark)"
            }
            sql += " ORDER BY visit.at"
            var byDay: [String: [Visit]] = [:]
            for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)) {
                byDay[row["day"], default: []].append(
                    try Feed.decoder.decode(Visit.self, from: row["json"] as Data))
            }

            var stored: [String: StoredDay] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT day, json FROM day") {
                stored[row["day"]] = try Feed.decoder.decode(StoredDay.self, from: row["json"] as Data)
            }
            // A day with only a note still belongs to the whole journal.
            var keys = Set(byDay.keys)
            if lens.bird == nil && !lens.kept {
                keys.formUnion(stored.filter { $0.value.note != nil }.keys)
            }
            return keys.sorted(by: >).map { key in
                let visits = byDay[key] ?? []
                let s = stored[key]
                let media = Dictionary(visits.flatMap(\.media).map { ($0.id, $0) }) { a, _ in a }
                var best = (s?.best ?? []).compactMap { media[$0] }
                if lens.bird != nil || lens.kept || best.isEmpty {
                    best = Self.bestPhotos(visits).compactMap { media[$0] }
                }
                let whole = lens.bird == nil && !lens.kept
                return Day(day: key, note: lens.bird == nil ? s?.note : nil, best: best, visits: visits,
                           reel: whole ? s?.reel : nil)
            }
        }
    }

    /// Every visit a lens holds, newest first.
    public func visits(_ lens: Lens) throws -> [Visit] {
        try days(lens).flatMap { $0.visits.reversed() }
    }

    /// The story of the week a day is in, as it stood at the week's end.
    public func story(weekOf day: String) throws -> Writing? {
        guard let start = calendar.monday(of: day) else { return nil }
        return try db.read { db in
            try Data.fetchOne(db, sql: "SELECT json FROM week WHERE start = ?", arguments: [start])
                .map { try Feed.decoder.decode(Writing.self, from: $0) }
        }
    }

    public func visit(_ id: String) throws -> Visit? {
        try db.read { db in
            try Data.fetchOne(db, sql: "SELECT json FROM visit WHERE id = ?", arguments: [id])
                .map { try Feed.decoder.decode(Visit.self, from: $0) }
        }
    }

    /// Every bird, the yard list's order first, then by most recent.
    public func birds() throws -> [Bird] {
        try db.read { db in
            try Data.fetchAll(db, sql: "SELECT json FROM bird")
                .map { try Feed.decoder.decode(Bird.self, from: $0) }
        }
        .sorted { ($0.yardNo ?? .max, -$0.lastSeen.timeIntervalSince1970)
                < ($1.yardNo ?? .max, -$1.lastSeen.timeIntervalSince1970) }
    }

    public func bird(_ key: String) throws -> Bird? {
        try db.read { db in
            try Data.fetchOne(db, sql: "SELECT json FROM bird WHERE key = ?", arguments: [key])
                .map { try Feed.decoder.decode(Bird.self, from: $0) }
        }
    }

    /// The feeder as the collector last read it.
    public func feeder() throws -> Feeder? { try meta("now") }

    /// What the board on the wall knows right now.
    public func wall() throws -> Wall? { try meta("wall") }

    /// The birds likely this month that haven't come yet.
    public func likely() throws -> Likely? { try meta("likely") }

    /// When the feed we hold was made.
    public func generatedAt() throws -> Date? { try meta("generated_at") }

    /// The address of a media file, from its path in the feed.
    public func url(_ path: String?) -> URL? {
        guard let path, let base: URL = try? meta("media") else { return nil }
        return URL(string: path, relativeTo: base)?.absoluteURL
    }

    func meta<T: Decodable>(_ key: String) throws -> T? {
        try db.read { db in
            try Data.fetchOne(db, sql: "SELECT json FROM meta WHERE key = ?", arguments: [key])
                .map { try Feed.decoder.decode(T.self, from: $0) }
        }
    }

    // MARK: - Kept

    public func isKept(_ visit: String, media: String? = nil) throws -> Bool {
        try db.read { db in
            try Bool.fetchOne(db, sql: "SELECT 1 FROM mark WHERE visit = ? AND media = ?",
                              arguments: [visit, media ?? ""]) ?? false
        }
    }

    public func setKept(_ kept: Bool, _ mark: Mark) throws {
        try db.write { db in
            if kept {
                try db.execute(sql: "INSERT OR REPLACE INTO mark (visit, media, at) VALUES (?, ?, ?)",
                               arguments: [mark.visit, mark.media ?? "", mark.at.timeIntervalSince1970])
            } else {
                try db.execute(sql: "DELETE FROM mark WHERE visit = ? AND media = ?",
                               arguments: [mark.visit, mark.media ?? ""])
            }
        }
        changed()
    }

    // MARK: - Corrections

    /// Say a visit's bird is really this one.
    public func correct(_ correction: Correction) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO correction (id, visit, name, at) VALUES (?, ?, ?, ?)",
                           arguments: [correction.id, correction.visit, correction.name,
                                       correction.at.timeIntervalSince1970])
        }
        changed()
    }

    /// The latest correction of a visit that the feed doesn't show yet.
    public func pendingCorrection(of visit: Visit) throws -> Correction? {
        let latest = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM correction WHERE visit = ? ORDER BY at DESC LIMIT 1",
                             arguments: [visit.id])
        }
        guard let latest else { return nil }
        let name: String = latest["name"]
        let landed = visit.by == "owner" && visit.birds.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        return landed ? nil : Correction(id: latest["id"], visit: latest["visit"], name: name,
                                         at: Date(timeIntervalSince1970: latest["at"]))
    }

    /// This phone's id in the inbox, made once.
    func deviceID() throws -> String {
        if let id: String = try meta("device") { return id }
        let id = UUID().uuidString
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO meta (key, json) VALUES ('device', ?)",
                           arguments: [try Feed.encoder.encode(id)])
        }
        return id
    }

    // MARK: - Notifications

    /// What this phone wants to be told; the starting set until someone chooses.
    public func notifySettings() -> NotifySettings {
        ((try? meta("notify")) as NotifySettings?) ?? .start
    }

    public func setNotify(_ settings: NotifySettings) throws {
        try setMeta("notify", settings)
        changed()
    }

    /// Where Apple reaches this phone, once it has said.
    public func pushAddress() -> PushAddress? {
        (try? meta("push")) ?? nil
    }

    public func setPush(_ address: PushAddress) throws {
        try setMeta("push", address)
    }

    func setMeta<T: Encodable>(_ key: String, _ value: T) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO meta (key, json) VALUES (?, ?)",
                           arguments: [key, try Feed.encoder.encode(value)])
        }
    }

    /// This phone's notifications as the inbox holds them; nothing until
    /// Apple has given it an address.
    func wireDevice(_ device: String) throws -> Feed.WireDevice? {
        guard let push = pushAddress(), push.token != nil else { return nil }
        let settings = notifySettings()
        return Feed.WireDevice(device: device, token: push.token, env: push.env, status: push.status,
                               kinds: settings.kinds.map(\.rawValue).sorted(), follow: settings.follow.sorted())
    }

    /// Everything this phone has marked, as the inbox holds it.
    func wireMarks(device: String) throws -> [Feed.WireMark] {
        try db.read { db in
            let keeps = try Row.fetchAll(db, sql: "SELECT * FROM mark").map { row -> Feed.WireMark in
                let media: String = row["media"]
                return Feed.WireMark(id: "keep:\(row["visit"] as String):\(media)", kind: "keep",
                                     visit: row["visit"], media: media.isEmpty ? nil : media, name: nil,
                                     at: Date(timeIntervalSince1970: row["at"]), device: device)
            }
            let corrections = try Row.fetchAll(db, sql: "SELECT * FROM correction").map {
                Feed.WireMark(id: $0["id"], kind: "correct", visit: $0["visit"], media: nil, name: $0["name"],
                              at: Date(timeIntervalSince1970: $0["at"]), device: device)
            }
            return keeps + corrections
        }
    }

    /// A day's best photos by Claude's score, one per bird before any second
    /// of the same bird; the feed's rule for days (collector/feed.py).
    static func bestPhotos(_ visits: [Visit], count: Int = 4) -> [String] {
        let scored = visits.filter { $0.best != nil && ($0.score ?? 2) > 1 }
            .sorted { (($0.score ?? 2), $0.at) > (($1.score ?? 2), $1.at) }
        var picked: [Visit] = [], birds: Set<String> = []
        for v in scored where birds.insert(v.bird?.bird ?? "").inserted { picked.append(v) }
        picked += scored.filter { v in !picked.contains { $0.id == v.id } }
        return picked.prefix(count).compactMap(\.best)
    }
}

/// One day as a lens shows it.
public struct Day: Hashable, Sendable {
    public var day: String
    public var note: Writing?
    public var best: [Media]
    public var visits: [Visit]
    /// The day in under a minute, for the whole journal's days.
    public var reel: Reel?
}

/// What the store keeps of a day file besides its visits.
struct StoredDay: Codable {
    var note: Writing?
    var best: [String]
    var reel: Reel?
}
