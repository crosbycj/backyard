import AVFoundation
import QuartzCore

/// The video's sound under your thumb while you scrub: each move of the
/// dial plays a short slice of the audio at that instant, faded in and out,
/// the way editing apps scrub, instead of silence. Turn it fast and you hear
/// the visit rush by; hold still and it goes quiet. The sound is decoded
/// once into memory (a minute of mono is a few megabytes), from the file on
/// the phone, fetched if it isn't there yet.
final class ScrubAudio {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    private var samples: [Float] = []
    private var lastGrain: CFTimeInterval = 0
    private var lastAt: Double?

    private static let rate: Double = 44_100
    /// How long each slice plays, and how often a new one may start.
    private static let grain = 0.1
    private static let every = 0.055
    private static let fade = 0.012

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    /// Decode the video's sound. Quietly does nothing if it has none.
    func load(_ asset: AVAsset) async {
        guard let url = (asset as? AVURLAsset)?.url else { return }
        let file = url.isFileURL ? url : await ImageLoader.shared.localFile(url)
        guard let file else { return }
        let local = AVURLAsset(url: file)
        guard let track = try? await local.loadTracks(withMediaType: .audio).first else { return }
        let samples = await Task.detached(priority: .utility) { Self.decode(local, track) }.value
        await MainActor.run { self.samples = samples }
    }

    private static func decode(_ asset: AVURLAsset, _ track: AVAssetTrack) -> [Float] {
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        ])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        reader.startReading()
        var all: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var part = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            part.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            all += part
        }
        return all
    }

    /// The scrub reached this instant: a slice from here, unless one just
    /// started or the dial hasn't moved.
    func play(at seconds: Double) {
        guard !samples.isEmpty else { return }
        let now = CACurrentMediaTime()
        guard now - lastGrain >= Self.every, lastAt.map({ abs($0 - seconds) > 0.01 }) ?? true else { return }
        lastGrain = now
        lastAt = seconds
        let count = Int(Self.grain * Self.rate), fade = Int(Self.fade * Self.rate)
        let start = min(max(Int(seconds * Self.rate), 0), max(samples.count - count, 0))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let out = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(min(count, samples.count - start))
        for i in 0..<Int(buffer.frameLength) {
            let edge = min(i, Int(buffer.frameLength) - 1 - i)
            out[i] = samples[start + i] * (edge < fade ? Float(edge) / Float(fade) : 1)
        }
        if !engine.isRunning { try? engine.start() }
        node.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !node.isPlaying { node.play() }
    }

    func stop() {
        node.stop()
        lastAt = nil
    }
}
