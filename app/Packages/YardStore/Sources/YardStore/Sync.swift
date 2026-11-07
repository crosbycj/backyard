import Foundation
import GRDB
import YardModel

extension YardStore {
    public struct SyncResult: Sendable {
        /// Feed files fetched because their hash changed.
        public var fetched: Int
        public var generatedAt: Date
    }

    /// Bring the phone's copy up to the feed: read the index, fetch the
    /// files whose hash changed, and drop the ones the feed no longer has.
    @discardableResult
    public func sync(session: URLSession = .shared) async throws -> SyncResult {
        let index = try Feed.decoder.decode(Feed.Index.self, from: try await fetch(feedURL, session))
        let wanted = index.days.map { File(kind: .day, entry: $0) }
            + index.weeks.map { File(kind: .week, entry: $0) }
            + index.birds.map { File(kind: .bird, entry: $0) }
        let have = try await db.read { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT path, hash FROM file")
                .map { ($0["path"] as String, $0["hash"] as String) })
        }
        let changed = wanted.filter { have[$0.path] != $0.entry.hash }
        let bodies = try await withThrowingTaskGroup(of: (File, Data).self) { group in
            for file in changed {
                group.addTask { [feedURL] in
                    (file, try await self.fetch(URL(string: file.path, relativeTo: feedURL)!, session))
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        let gone = Set(have.keys).subtracting(wanted.map(\.path))
        try await db.write { db in
            for (file, data) in bodies { try self.apply(file, data, db) }
            for path in gone { try self.remove(path, db) }
            var meta = [("media", try Feed.encoder.encode(index.media)),
                        ("now", try Feed.encoder.encode(index.now)),
                        ("generated_at", try Feed.encoder.encode(index.generatedAt)),
                        ("yard_list", try Feed.encoder.encode(index.yardList))]
            // A feed made without the board (feed.py by hand) keeps the last wall.
            if let wall = index.wall { meta.append(("wall", try Feed.encoder.encode(wall))) }
            if let inbox = index.inbox { meta.append(("inbox", try Feed.encoder.encode(inbox))) }
            if let likely = index.likely { meta.append(("likely", try Feed.encoder.encode(likely))) }
            for (key, value) in meta {
                try db.execute(sql: "INSERT OR REPLACE INTO meta (key, json) VALUES (?, ?)",
                               arguments: [key, value])
            }
        }
        self.changed()
        return SyncResult(fetched: bodies.count, generatedAt: index.generatedAt)
    }

    /// Put this phone's marks (what it kept, the birds it corrected) and
    /// what it wants to be told in the inbox the collector reads, beside
    /// other phones'. Only when they differ from what's there. Returns
    /// whether anything was sent.
    @discardableResult
    public func sendMarks(session: URLSession = .shared) async throws -> Bool {
        guard let inbox: Feed.Inbox = try meta("inbox") else { return false }
        let device = try deviceID()
        let mine = try wireMarks(device: device)
        let me = try wireDevice(device)
        var request = URLRequest(url: inbox.get.appending(queryItems: [
            URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 404 else { throw URLError(.badServerResponse) }
        let file = status == 200 ? try? Feed.decoder.decode(Feed.Marks.self, from: data) : nil
        let there = file?.marks ?? [], devices = file?.devices ?? []
        let theirs = there.filter { $0.device != device }
        let others = devices.filter { $0.device != device }
        guard Set(there.filter { $0.device == device }.map(\.id)) != Set(mine.map(\.id))
                || devices.first(where: { $0.device == device }) != me else { return false }
        var put = URLRequest(url: inbox.put)
        put.httpMethod = "PUT"
        put.setValue("application/json", forHTTPHeaderField: "Content-Type")
        put.httpBody = try Feed.encoder.encode(Feed.Marks(marks: theirs + mine, devices: others + [me].compactMap { $0 }))
        let (_, sent) = try await session.data(for: put)
        guard (sent as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return true
    }

    struct File: Sendable {
        enum Kind: String, Sendable { case day = "days", week = "weeks", bird = "birds" }
        var kind: Kind
        var entry: Feed.Entry
        var path: String { "\(kind.rawValue)/\(entry.key).json" }
    }

    func fetch(_ url: URL, _ session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLErrorKey: url])
        }
        return data
    }

    func apply(_ file: File, _ data: Data, _ db: Database) throws {
        let key = file.entry.key
        switch file.kind {
        case .day:
            let day = try Feed.decoder.decode(Feed.Day.self, from: data)
            try db.execute(sql: "DELETE FROM visit WHERE day = ?", arguments: [key])
            for visit in day.visits {
                try db.execute(sql: "INSERT OR REPLACE INTO visit (id, day, at, json) VALUES (?, ?, ?, ?)",
                               arguments: [visit.id, key, visit.at.timeIntervalSince1970,
                                           try Feed.encoder.encode(visit)])
                for bird in Set(visit.birds.compactMap(\.bird)) {
                    try db.execute(sql: "INSERT OR IGNORE INTO visitBird (visit, bird) VALUES (?, ?)",
                                   arguments: [visit.id, bird])
                }
            }
            let note = day.note.map {
                Writing(kind: .dayNote, start: key, end: key, paragraphs: [.init(text: $0.text)],
                        by: $0.by, writtenAt: $0.writtenAt)
            }
            try db.execute(sql: "INSERT OR REPLACE INTO day (day, json) VALUES (?, ?)",
                           arguments: [key, try Feed.encoder.encode(StoredDay(note: note, best: day.best, reel: day.reel))])
        case .week:
            let week = try Feed.decoder.decode(Feed.Week.self, from: data)
            if let s = week.story {
                let story = Writing(kind: .story, start: week.week, end: week.end, dateline: s.dateline,
                                    paragraphs: s.paragraphs, by: s.by, writtenAt: s.writtenAt,
                                    versions: s.versions)
                try db.execute(sql: "INSERT OR REPLACE INTO week (start, json) VALUES (?, ?)",
                               arguments: [key, try Feed.encoder.encode(story)])
            } else {
                try db.execute(sql: "DELETE FROM week WHERE start = ?", arguments: [key])
            }
        case .bird:
            let bird = try Feed.decoder.decode(Bird.self, from: data)
            try db.execute(sql: "INSERT OR REPLACE INTO bird (key, json) VALUES (?, ?)",
                           arguments: [key, try Feed.encoder.encode(bird)])
        }
        try db.execute(sql: "INSERT OR REPLACE INTO file (path, hash) VALUES (?, ?)",
                       arguments: [file.path, file.entry.hash])
    }

    func remove(_ path: String, _ db: Database) throws {
        let parts = path.split(separator: "/")
        guard parts.count == 2 else { return }
        let key = String(parts[1].dropLast(".json".count))
        switch parts[0] {
        case "days":
            try db.execute(sql: "DELETE FROM visit WHERE day = ?", arguments: [key])
            try db.execute(sql: "DELETE FROM day WHERE day = ?", arguments: [key])
        case "weeks": try db.execute(sql: "DELETE FROM week WHERE start = ?", arguments: [key])
        case "birds": try db.execute(sql: "DELETE FROM bird WHERE key = ?", arguments: [key])
        default: break
        }
        try db.execute(sql: "DELETE FROM file WHERE path = ?", arguments: [path])
    }
}
