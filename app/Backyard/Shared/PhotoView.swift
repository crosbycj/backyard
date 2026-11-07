import ImageIO
import UIKit
import YardModel

/// Photos, fast. The feed's media never change, so each file is fetched
/// once into Caches and kept. It's decoded off the main thread at the size
/// it's shown (not the photo's 2048 px), and kept decoded in memory by that
/// size. Asking twice for the same photo while it's on its way waits on the
/// one request.
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    /// Decoded sizes, in pixels on the long edge. A request rounds up to one.
    private static let buckets: [CGFloat] = [192, 384, 768, 1280, 2048]

    private let memory = NSCache<NSString, UIImage>()
    private let folder: URL
    private let session: URLSession
    private let lock = NSLock()
    private var downloads: [URL: Task<URL?, Never>] = [:]
    private var decodes: [NSString: Task<UIImage?, Never>] = [:]

    init() {
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("media-v2")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.default
        config.urlCache = nil  // our own folder is the cache
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)
        memory.totalCostLimit = 220 << 20
    }

    static func bucket(_ pixels: CGFloat) -> CGFloat { buckets.first { $0 >= pixels } ?? buckets.last! }

    private func key(_ url: URL, _ bucket: CGFloat) -> NSString { "\(Int(bucket))|\(url.absoluteString)" as NSString }

    /// The photo decoded at this size or larger, if it's in memory.
    func cached(_ url: URL, pixels: CGFloat) -> UIImage? {
        let wanted = Self.bucket(pixels)
        for b in Self.buckets where b >= wanted {
            if let image = memory.object(forKey: key(url, b)) { return image }
        }
        return nil
    }

    /// Any decoded size of the photo in memory, to show while a sharper one loads.
    func anyCached(_ url: URL) -> UIImage? {
        for b in Self.buckets.reversed() {
            if let image = memory.object(forKey: key(url, b)) { return image }
        }
        return nil
    }

    func image(_ url: URL, pixels: CGFloat, priority: TaskPriority = .userInitiated) async -> UIImage? {
        if let hit = cached(url, pixels: pixels) { return hit }
        let bucket = Self.bucket(pixels)
        let k = key(url, bucket)
        let task = lock.withLock { () -> Task<UIImage?, Never> in
            if let running = decodes[k] { return running }
            let task = Task.detached(priority: priority) { [self] () -> UIImage? in
                guard let file = await self.file(url, priority: priority) else { return nil }
                return Self.decode(file, pixels: bucket)
            }
            decodes[k] = task
            return task
        }
        let image = await task.value
        lock.withLock { decodes[k] = nil }
        if let image, let cg = image.cgImage {
            memory.setObject(image, forKey: k, cost: cg.bytesPerRow * cg.height)
        }
        return image
    }

    /// Fetch photos ahead of being shown: decoded at this size, at low priority.
    func prefetch(_ urls: [URL], pixels: CGFloat) {
        for url in urls where cached(url, pixels: pixels) == nil {
            Task.detached(priority: .utility) { _ = await self.image(url, pixels: pixels, priority: .utility) }
        }
    }

    /// Fetch files onto the phone without decoding them, a few at a time:
    /// after a sync, so the newest days open with no wait.
    func download(_ urls: [URL]) {
        Task.detached(priority: .background) {
            await withTaskGroup(of: Void.self) { group in
                for (i, url) in urls.enumerated() {
                    if i >= 4 { await group.next() }
                    group.addTask { _ = await self.file(url, priority: .background) }
                }
            }
        }
    }

    /// The file itself (a full-size photo or a video), fetched if it isn't
    /// on the phone yet: for saving to Photos.
    func localFile(_ url: URL) async -> URL? { await file(url, priority: .userInitiated) }

    /// The photo's file on the phone, fetched the first time.
    private func file(_ url: URL, priority: TaskPriority) async -> URL? {
        let name = url.path.replacingOccurrences(of: "/", with: "_")
        let local = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        let task = lock.withLock { () -> Task<URL?, Never> in
            if let running = downloads[url] { return running }
            let task = Task.detached(priority: priority) { [session] () -> URL? in
                guard let (temp, response) = try? await session.download(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                try? FileManager.default.removeItem(at: local)
                return (try? FileManager.default.moveItem(at: temp, to: local)) != nil ? local : nil
            }
            downloads[url] = task
            return task
        }
        let result = await task.value
        lock.withLock { downloads[url] = nil }
        return result
    }

    private static func decode(_ file: URL, pixels: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// A photo that fills its frame, keeping the bird in view: it's cropped
/// around Claude's box instead of the middle. It loads at the size it's
/// laid out at, and never shows a photo meant for something else.
final class PhotoView: UIView {
    private let imageView = UIImageView()
    private var task: Task<Void, Never>?
    private(set) var url: URL?
    private var loadedPixels: CGFloat = 0
    /// Where the bird is, as shares of the photo's width and height.
    var focus = CGPoint(x: 0.5, y: 0.5) { didSet { setNeedsLayout() } }
    /// Claude's box around the bird, when it's known.
    private var box: Box?
    /// A face: zoom in until the bird's box, this much bigger, fills the frame.
    var faceZoom: CGFloat? { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = Style.rule
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The pixels its long edge needs: the frame at the screen's scale, with
    /// room for the crop (a 3:4 photo filling a wide frame).
    static func pixels(for size: CGSize, scale: CGFloat = UIScreen.main.scale) -> CGFloat {
        max(size.width, size.height) * scale * 1.4
    }

    func show(_ url: URL?, box: Box? = nil) {
        self.box = box
        focus = box.map { CGPoint(x: ($0.left + $0.right) / 2, y: ($0.top + $0.bottom) / 2) } ?? CGPoint(x: 0.5, y: 0.5)
        guard url != self.url else { return }
        self.url = url
        task?.cancel()
        task = nil
        loadedPixels = 0
        imageView.image = url.flatMap(ImageLoader.shared.anyCached)
        setNeedsLayout()
        load()
    }

    /// Load at the laid-out size, once the size is known and only if what's
    /// showing is smaller than that.
    private func load() {
        guard let url, bounds.width > 0 else { return }
        var pixels = Self.pixels(for: bounds.size)
        // A face shows a small part of the photo, so it needs more of it.
        if let zoom = faceZoom, let box {
            let span = max(box.right - box.left, (box.bottom - box.top) * 0.75) * zoom
            pixels = min(pixels / max(span, 0.05), 2048)
        }
        guard ImageLoader.bucket(pixels) > loadedPixels else { return }
        if let image = ImageLoader.shared.cached(url, pixels: pixels) {
            imageView.image = image
            loadedPixels = ImageLoader.bucket(pixels)
            setNeedsLayout()
            return
        }
        guard task == nil else { return }
        let fadeIn = imageView.image == nil
        task = Task { [weak self] in
            let image = await ImageLoader.shared.image(url, pixels: pixels)
            guard let self, !Task.isCancelled, self.url == url, let image else { return }
            self.task = nil
            self.loadedPixels = ImageLoader.bucket(pixels)
            self.imageView.image = image
            self.setNeedsLayout()
            if fadeIn {
                self.imageView.alpha = 0
                UIView.animate(withDuration: 0.15) { self.imageView.alpha = 1 }
            }
        }
    }

    /// Where the photo is drawn, uncropped, in its own points.
    var pictureFrame: CGRect { imageView.image == nil ? bounds : imageView.frame }

    /// Width over height, of the photo or else of the frame.
    var pictureAspect: CGFloat {
        let size = pictureFrame.size
        return size.height > 0 ? size.width / size.height : 0.75
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        load()
        guard let size = imageView.image?.size, size.width > 0, size.height > 0, bounds.width > 0 else {
            imageView.frame = bounds
            return
        }
        // Aspect fill (or closer, for a face), then slide toward the bird as
        // far as the photo allows.
        var scale = max(bounds.width / size.width, bounds.height / size.height)
        if let zoom = faceZoom, let box {
            let w = (box.right - box.left) * size.width * zoom, h = (box.bottom - box.top) * size.height * zoom
            scale = max(scale, bounds.width / max(w, h, 1))
        }
        let w = size.width * scale, h = size.height * scale
        // A face looks toward the top of the box, where the head is.
        let focusY = faceZoom != nil ? box.map { $0.top + ($0.bottom - $0.top) * 0.42 } ?? focus.y : focus.y
        let x = min(0, max(bounds.width - w, bounds.width / 2 - focus.x * w))
        let y = min(0, max(bounds.height - h, bounds.height / 2 - focusY * h))
        imageView.frame = CGRect(x: x, y: y, width: w, height: h)
    }
}
