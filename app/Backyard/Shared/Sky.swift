import SwiftUI
import UIKit

/// The page as the sky over the yard: a few shades of the stone, tinted at
/// the top and bottom edges (where the glass is) by where the sun is right
/// now, warmest on the side the sun is on, and muted when it's grey out.
/// The middle, where you read, stays the paper.
///
/// The sky is a mesh of colors, picked from keyframes by the sun's height
/// (night, nautical twilight, the blue hour, the horizon, golden hour,
/// morning, midday) and blended in OKLab so the in-betweens stay clean.
@MainActor
final class Sky: ObservableObject {
    static let shared = Sky()

    /// A moment to show instead of now: the scrubber's, or `-skyMinutes`.
    @Published var override: Date?
    /// Weather to show instead of the board's, 0 clear to 1 rain.
    @Published var overcastOverride: Double?
    /// How grey it is by the board's weather, 0 clear to 1 rain.
    @Published private(set) var overcast = 0.6

    var now: Date { override ?? .now }
    var grey: Double { overcastOverride ?? overcast }

    private init() {
        // Debug: launch with -skyMinutes 1150 (minutes past midnight) and -skyWeather clear.
        let defaults = UserDefaults.standard
        if let minutes = defaults.string(forKey: "skyMinutes").flatMap(Double.init) {
            override = Yard.calendar.calendar.startOfDay(for: .now).addingTimeInterval(minutes * 60)
        }
        if let words = defaults.string(forKey: "skyWeather") { overcastOverride = Self.overcast(of: words) }
    }

    /// The board's weather ("47°, cloudy") as how grey it is.
    func weather(_ text: String?) {
        overcast = Self.overcast(of: text)
    }

    static func overcast(of text: String?) -> Double {
        guard let text = text?.lowercased() else { return 0.6 }
        if ["rain", "drizzle", "shower", "storm", "snow"].contains(where: text.contains) { return 1 }
        if ["partly", "few", "scattered", "mostly sunny", "mostly clear"].contains(where: text.contains) { return 0.4 }
        if ["clear", "sunny", "fair"].contains(where: text.contains) { return 0 }
        if ["cloud", "overcast", "fog", "mist", "haze", "grey", "gray"].contains(where: text.contains) { return 0.85 }
        return 0.6
    }

    // MARK: - The sun

    /// The feeder's town, to the nearest few miles: plenty for where the sun is.
    /// Set these to yours.
    static let latitude = 0.0, longitude = 0.0

    /// The sun's height above the horizon and its compass bearing, in degrees.
    static func sun(at date: Date) -> (elevation: Double, azimuth: Double) {
        let rad = Double.pi / 180
        let n = date.timeIntervalSince1970 / 86400 + 2_440_587.5 - 2_451_545.0
        let mean = (280.460 + 0.985_647_4 * n).truncatingRemainder(dividingBy: 360)
        let anomaly = (357.528 + 0.985_600_3 * n).truncatingRemainder(dividingBy: 360) * rad
        let ecliptic = (mean + 1.915 * sin(anomaly) + 0.020 * sin(2 * anomaly)) * rad
        let tilt = (23.439 - 0.000_000_4 * n) * rad
        let ascension = atan2(cos(tilt) * sin(ecliptic), cos(ecliptic))
        let declination = asin(sin(tilt) * sin(ecliptic))
        let sidereal = (18.697_374_558 + 24.065_709_824_419_08 * n).truncatingRemainder(dividingBy: 24) * 15
        let hour = (sidereal + longitude) * rad - ascension
        let lat = latitude * rad
        let elevation = asin(sin(lat) * sin(declination) + cos(lat) * cos(declination) * cos(hour))
        let azimuth = atan2(-sin(hour), tan(declination) * cos(lat) - sin(lat) * cos(hour))
        return (elevation / rad, (azimuth / rad + 360).truncatingRemainder(dividingBy: 360))
    }

    // MARK: - The colors

    /// One of the sky's moments, as the light page would wear it: the sky
    /// at the top, the light just under it, the ground at the bottom, and
    /// the glow on the side the sun is on.
    private struct Moment {
        var elevation: Double
        var sky: UInt32, horizon: UInt32, ground: UInt32, glow: UInt32
    }

    private static let moments: [Moment] = [
        Moment(elevation: -18, sky: 0xD3D9DF, horizon: 0xE2E5E6, ground: 0xE3E5E2, glow: 0xD3D9DF),  // night
        Moment(elevation: -10, sky: 0xC8D0DC, horizon: 0xDCDDE4, ground: 0xE1E1E3, glow: 0xD2D0DE),  // nautical twilight
        Moment(elevation: -4, sky: 0xC4CEE0, horizon: 0xE6DCE2, ground: 0xE4E0E4, glow: 0xE8D2D8),   // the blue hour
        Moment(elevation: 0, sky: 0xD3D3E0, horizon: 0xEEDDD3, ground: 0xECE2DA, glow: 0xF3CCAA),    // the horizon
        Moment(elevation: 5, sky: 0xDFE0DC, horizon: 0xF1E6D4, ground: 0xEFE7D8, glow: 0xF5D8A8),    // golden hour
        Moment(elevation: 15, sky: 0xD3DFE8, horizon: 0xEAEDE8, ground: 0xE9ECE4, glow: 0xF6ECD6),   // morning, afternoon
        Moment(elevation: 40, sky: 0xCEDDEA, horizon: 0xEBEEEA, ground: 0xE8ECE5, glow: 0xF7F2E2),   // midday
    ]

    private static let lightPaper = Lab(0xF0EFE7), darkPaper = Lab(0x10120F)

    /// The mesh's twelve colors, three across and four down, for a moment.
    func colors(at date: Date, dark: Bool) -> [Color] {
        let (elevation, azimuth) = Self.sun(at: date)
        let moments = Self.moments
        let i = moments.lastIndex { $0.elevation <= elevation } ?? 0
        let a = moments[i], b = moments[min(i + 1, moments.count - 1)]
        let span = b.elevation - a.elevation
        let t = span > 0 ? Self.smooth(min(max((elevation - a.elevation) / span, 0), 1)) : 0
        func at(_ key: KeyPath<Moment, UInt32>) -> Lab { Lab(a[keyPath: key]).mix(Lab(b[keyPath: key]), t) }
        let sky = at(\.sky), horizon = at(\.horizon), ground = at(\.ground), glow = at(\.glow)

        // East on the left, west on the right, as if looking south over the
        // yard. Low, the sun's glow spreads along the horizon; high, it's a
        // smaller patch of light in a sky that's mostly sky.
        let sunX = min(max((azimuth - 90) / 180, -0.2), 1.2)
        let high = min(max((elevation - 2) / 12, 0), 1)
        let spread = 0.32 - 0.12 * high, strength = 1 - 0.5 * high
        func warmth(_ x: Double) -> Double { strength * exp(-pow(x - sunX, 2) / (2 * spread * spread)) }

        let paper = Self.lightPaper
        var lab: [Lab] = []
        for x in [0.0, 0.5, 1.0] { lab.append(sky.mix(glow, warmth(x))) }
        for x in [0.0, 0.5, 1.0] { lab.append(paper.mix(horizon.mix(glow, warmth(x) * 0.5), 0.45)) }
        for _ in 0..<3 { lab.append(paper.mix(horizon, 0.06)) }
        for x in [0.0, 0.5, 1.0] { lab.append(paper.mix(ground.mix(glow, warmth(x) * 0.25), 0.85)) }

        // Grey weather takes most of the color and some of the depth.
        let keep = 1 - 0.65 * grey, depth = 1 - 0.3 * grey
        return lab.map { color in
            var tint = Lab(L: (color.L - paper.L) * depth, a: color.a * keep, b: color.b * keep)
            // The dark page wears the same sky a little lighter than its paper.
            if dark { tint = Lab(L: -tint.L * 0.6, a: tint.a * 0.85, b: tint.b * 0.85) }
            let base = dark ? Self.darkPaper : paper
            return Lab(L: base.L + tint.L, a: base.a + tint.a, b: base.b + tint.b).color
        }
    }

    private static func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    /// A color in OKLab: lightness and two axes of hue, where mixing looks
    /// even to the eye.
    private struct Lab {
        var L: Double, a: Double, b: Double

        init(L: Double, a: Double, b: Double) { self.L = L; self.a = a; self.b = b }

        init(_ hex: UInt32) {
            func linear(_ c: UInt32) -> Double {
                let v = Double(c) / 255
                return v <= 0.040_45 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            let r = linear(hex >> 16 & 0xFF), g = linear(hex >> 8 & 0xFF), bl = linear(hex & 0xFF)
            let l = cbrt(0.412_221_470_8 * r + 0.536_332_536_3 * g + 0.051_445_992_9 * bl)
            let m = cbrt(0.211_903_498_2 * r + 0.680_699_545_1 * g + 0.107_396_956_6 * bl)
            let s = cbrt(0.088_302_461_9 * r + 0.281_718_837_6 * g + 0.629_978_700_5 * bl)
            L = 0.210_454_255_3 * l + 0.793_617_785_0 * m - 0.004_072_046_8 * s
            a = 1.977_998_495_1 * l - 2.428_592_205_0 * m + 0.450_593_709_9 * s
            b = 0.025_904_037_1 * l + 0.782_771_766_2 * m - 0.808_675_766_0 * s
        }

        func mix(_ other: Lab, _ t: Double) -> Lab {
            Lab(L: L + (other.L - L) * t, a: a + (other.a - a) * t, b: b + (other.b - b) * t)
        }

        var color: Color {
            let l = pow(L + 0.396_337_777_4 * a + 0.215_803_757_3 * b, 3)
            let m = pow(L - 0.105_561_345_8 * a - 0.063_854_172_8 * b, 3)
            let s = pow(L - 0.089_484_177_5 * a - 1.291_485_548_0 * b, 3)
            func gamma(_ v: Double) -> Double {
                let c = min(max(v, 0), 1)
                return c <= 0.003_130_8 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
            }
            return Color(.sRGB,
                         red: gamma(4.076_741_662_1 * l - 3.307_711_591_3 * m + 0.230_969_929_2 * s),
                         green: gamma(-1.268_438_004_6 * l + 2.609_757_401_1 * m - 0.341_319_396_5 * s),
                         blue: gamma(-0.004_196_086_3 * l - 0.703_418_614_7 * m + 1.707_614_701_0 * s))
        }
    }

    // MARK: - The grain

    /// Noise around middle grey, laid over the sky in overlay so each speck
    /// is a few levels lighter or darker, light or dark page alike.
    static let grain: UIImage = {
        let side = 256
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        var seed: UInt32 = 0x5EED
        func roll() -> Int {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Int(seed >> 24) % 21
        }
        for i in 0..<side * side {
            let v = UInt8(clamping: 128 + 2 * (roll() - roll()))
            pixels[i * 4] = v; pixels[i * 4 + 1] = v; pixels[i * 4 + 2] = v
        }
        let image = CGDataProvider(data: Data(pixels) as CFData).flatMap {
            CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                    provider: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        return image.map { UIImage(cgImage: $0, scale: UIScreen.main.scale, orientation: .up) } ?? UIImage()
    }()
}

/// The sky as a mesh, drifting a little (unless Reduce Motion is on), with
/// the grain over it.
struct SkyView: View {
    @ObservedObject private var sky = Sky.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        // The drift is slow (periods of 40 to 70 seconds), so a dozen frames
        // a second is plenty, and kinder to the battery.
        TimelineView(.periodic(from: .now, by: still ? 60 : 1.0 / 12)) { context in
            let t = still ? 0 : Float(context.date.timeIntervalSinceReferenceDate)
            MeshGradient(width: 3, height: 4, points: points(t), colors: sky.colors(at: sky.now, dark: scheme == .dark),
                         smoothsColors: true, colorSpace: .perceptual)
        }
        .overlay {
            Image(uiImage: Sky.grain).resizable(resizingMode: .tile).blendMode(.overlay)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// The mesh's points: the edges stay put, the inside breathes on long,
    /// unrelated periods so it never quite repeats.
    private func points(_ t: Float) -> [SIMD2<Float>] {
        func wave(_ period: Float, _ size: Float) -> Float { sin(t * 2 * .pi / period) * size }
        return [
            [0, 0], [0.5 + wave(53, 0.06), 0], [1, 0],
            [0, 0.3 + wave(41, 0.03)], [0.5 + wave(67, 0.05), 0.32 + wave(37, 0.03)], [1, 0.3 + wave(47, 0.03)],
            [0, 0.72 + wave(59, 0.03)], [0.5 + wave(43, 0.05), 0.72 + wave(61, 0.03)], [1, 0.72 + wave(53, 0.03)],
            [0, 1], [0.5 + wave(71, 0.06), 1], [1, 1],
        ]
    }
}

/// The sky behind a screen, as a UIKit view.
final class SkyBackdrop: UIView {
    private let host = UIHostingController(rootView: SkyView())

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        host.view.backgroundColor = .clear
        host.sizingOptions = []
        pin(host.view)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// For trying the sky: drag through today and pick the weather. Shown by
/// holding Today with two fingers.
final class SkyScrubber: UIView {
    private let label = UILabel(font: Style.weight(Style.footnote, .semibold), lines: 1)
    private let slider = UISlider()
    private let weather = UISegmentedControl(items: ["Now", "Clear", "Cloudy", "Rain"])

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        blur.layer.cornerRadius = Style.radius
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        pin(blur)
        slider.minimumValue = 0
        slider.maximumValue = 24 * 60
        slider.minimumTrackTintColor = Style.accent
        let sky = Sky.shared
        let start = Yard.calendar.calendar.startOfDay(for: .now)
        slider.value = Float(sky.now.timeIntervalSince(start) / 60)
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            sky.override = start.addingTimeInterval(Double(self.slider.value) * 60)
            self.show()
        }, for: .valueChanged)
        weather.selectedSegmentIndex = sky.overcastOverride.map { $0 < 0.3 ? 1 : $0 < 0.95 ? 2 : 3 } ?? 0
        weather.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            switch self.weather.selectedSegmentIndex {
            case 1: sky.overcastOverride = 0
            case 2: sky.overcastOverride = 0.85
            case 3: sky.overcastOverride = 1
            default:
                sky.overcastOverride = nil
                sky.override = nil
                self.slider.setValue(Float(Date.now.timeIntervalSince(start) / 60), animated: true)
            }
            self.show()
        }, for: .valueChanged)
        let stack = UIStackView(arrangedSubviews: [label, slider, weather])
        stack.axis = .vertical
        stack.spacing = 10
        blur.contentView.pin(stack, insets: UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16))
        show()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func show() {
        let sky = Sky.shared
        let sun = Sky.sun(at: sky.now)
        label.text = "\(Words.clockWithHalf.string(from: sky.now)) · sun \(Int(sun.elevation.rounded()))° · \(sky.override == nil ? "live" : "scrubbing")"
    }
}
