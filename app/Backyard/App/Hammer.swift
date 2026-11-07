#if DEBUG
import UIKit

/// `-hammer yes`: opens the first photo on Today and throws everything at
/// its card faster than a person would (grab it mid-growth, flick it away,
/// tap it back mid-shrink, over and over), logging where the card shows on
/// every frame to `hammer.json` in the app's temporary folder. A jump is a
/// frame where it moves much further than the frames around it.
@MainActor
enum Hammer {
    private static var log: [[String: Any]] = []
    private static var link: CADisplayLink?
    private static var event = ""
    private static let start = CACurrentMediaTime()

    static func run(on screen: UIViewController) async {
        guard let stage = CardStage.shared,
              let carousel = find(Carousel.self, in: screen.view),
              let strip = find(UICollectionView.self, in: carousel) else { print("hammer: no carousel"); return }
        let ticker = Ticker()
        link = CADisplayLink(target: ticker, selector: #selector(Ticker.tick))
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link?.add(to: .main, forMode: .common)

        func tapTile() { mark("open"); carousel.collectionView(strip, didSelectItemAt: IndexPath(item: 0, section: 0)) }
        func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        /// A finger on the card, moving `by` over `frames` frames, then let go at `speed`.
        func fling(by: CGPoint, frames: Int, speed: CGPoint) async {
            guard let card = stage.debugTop else { return }
            let f = card.frame()
            mark("grab")
            card.grab(CGPoint(x: f.midX, y: f.midY))
            for i in 1...frames {
                await wait(1 / 60)
                card.drag(CGPoint(x: by.x * CGFloat(i) / CGFloat(frames), y: by.y * CGFloat(i) / CGFloat(frames)))
            }
            mark("let go")
            card.letGo(speed, by)
        }
        func tapCard() { mark("tap card"); stage.debugTop?.tap() }

        await wait(0.5)
        tapTile()
        await wait(0.12)                                                     // still growing
        await fling(by: CGPoint(x: 0, y: 120), frames: 6, speed: CGPoint(x: 0, y: 1400))
        await wait(0.1)                                                      // mid-shrink
        tapCard()
        await wait(0.1)
        await fling(by: CGPoint(x: 30, y: 200), frames: 8, speed: CGPoint(x: 200, y: 1800))
        await wait(0.18)
        tapCard()
        await wait(0.7)                                                      // open and settled
        mark("close")
        if let top = stage.top { stage.close(containing: top) }
        await wait(0.15)
        tapCard()
        await wait(0.7)
        await fling(by: CGPoint(x: 0, y: 70), frames: 10, speed: CGPoint(x: 0, y: -150))  // a peek: stays open
        await wait(0.7)
        await fling(by: CGPoint(x: 0, y: 160), frames: 8, speed: CGPoint(x: 0, y: 900))
        await wait(0.05)
        tapTile()                                                            // the tile again, through the shrinking card's edge
        await wait(0.9)
        mark("close")
        if let top = stage.top { stage.close(containing: top) }
        await wait(0.9)

        link?.invalidate()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hammer.json")
        try? JSONSerialization.data(withJSONObject: log).write(to: url)
        print("hammer: \(log.count) frames → \(url.path)")
    }

    private static func mark(_ e: String) { event = e }

    fileprivate static func record() {
        guard let stage = CardStage.shared else { return }
        var row: [String: Any] = ["t": CACurrentMediaTime() - start, "e": event]
        event = ""
        if let card = stage.debugTop {
            let f = card.frame()
            row["x"] = f.midX; row["y"] = f.midY; row["w"] = f.width; row["h"] = f.height
        }
        if let top = stage.top { row["safe"] = top.view.safeAreaInsets.top }
        log.append(row)
    }

    private final class Ticker: NSObject {
        @objc func tick() { MainActor.assumeIsolated { Hammer.record() } }
    }

    private static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let match = find(type, in: sub) { return match } }
        return nil
    }
}
#endif
