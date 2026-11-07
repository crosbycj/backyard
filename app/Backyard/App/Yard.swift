import Foundation
import Network
import os
import WidgetKit
import YardModel
import YardStore

/// The app's one store, its copy of the yard, and keeping it in step with
/// the collector's feed.
@MainActor
enum Yard {
    static let calendar = YardCalendar()

    /// Whether the phone is on a metered connection (cellular, a hotspot):
    /// then videos come only when asked for, not ahead of time.
    nonisolated(unsafe) static private(set) var onCellular = false
    private static let path: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { onCellular = $0.isExpensive }
        monitor.start(queue: DispatchQueue(label: "yard.path"))
        return monitor
    }()

    /// Start watching the connection (once, at launch).
    static func watchConnection() { _ = path }

    static let store: YardStore = {
        let feed = Bundle.main.object(forInfoDictionaryKey: "YardFeedURL") as! String
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            return try YardStore(path: folder.appendingPathComponent("yard.sqlite"),
                                 feedURL: URL(string: feed)!, calendar: calendar)
        } catch {
            fatalError("Can't open the yard: \(error)")
        }
    }()

    private static let log = Logger(subsystem: "com.example.backyard", category: "sync")
    private static var syncing: Task<Void, Never>?
    static private(set) var lastError: Error?

    /// Sync with the feed, once at a time. Screens hear about it through
    /// YardStore.didChange.
    @discardableResult
    static func sync() -> Task<Void, Never> {
        if let syncing { return syncing }
        let task = Task {
            do {
                let result = try await store.sync()
                log.info("synced: \(result.fetched) file(s) fetched")
                lastError = nil
                preload()
                // The widget shows what the phone now knows.
                WidgetCenter.shared.reloadAllTimelines()
                try? await store.sendMarks()
            } catch {
                log.error("sync failed: \(String(describing: error), privacy: .public)")
                lastError = error
            }
            syncing = nil
        }
        syncing = task
        return task
    }

    /// Send what this phone marked (kept, corrected) to the collector's inbox.
    static func sendMarks() {
        Task {
            do { try await store.sendMarks() } catch {
                log.error("marks not sent: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Bring the newest week's photos onto the phone in the background, so
    /// the screens people open first never wait on the network.
    private static func preload() {
        let recent = ((try? store.days(.journal)) ?? []).prefix(7)
        let visits = recent.flatMap(\.visits).filter { $0.source != .report }
        let small = visits.flatMap(\.photos).compactMap { store.url($0.small) }
        let large = visits.compactMap { store.url($0.bestPhoto?.large) }
        ImageLoader.shared.download(large.prefix(24) + small)
    }
}
