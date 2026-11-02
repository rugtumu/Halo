import Accelerate
import AVFoundation
import SwiftUI

/// A low-rate stereo copy of a file's audio for waveform drawing and instant preview playback.
/// Exports never use it — they run ffmpeg on the original at full quality.
@MainActor
final class AudioPreview: ObservableObject {
    static let sampleRate = 22_050.0

    let buffer: AVAudioPCMBuffer
    let duration: Double
    let peaks: [Float]
    let leftPeaks: [Float]
    let rightPeaks: [Float]

    @Published private(set) var playing = false
    @Published private(set) var playhead: Double?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var timer: Timer?
    private var offset = 0.0
    private var generation = 0

    private init(buffer: AVAudioPCMBuffer, peaks: [Float], left: [Float], right: [Float]) {
        self.buffer = buffer
        duration = Double(buffer.frameLength) / buffer.format.sampleRate
        self.peaks = peaks
        leftPeaks = left
        rightPeaks = right
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
    }

    nonisolated static func load(_ url: URL) async throws -> AudioPreview {
        let temp = try Output.tempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let wav = temp.appendingPathComponent("preview.wav")
        do {
            try await MediaEngine.run(input: url, output: wav,
                                      ["-vn", "-ac", "2", "-ar", "\(Int(sampleRate))", "-c:a", "pcm_s16le"])
        } catch {
            throw HaloError("\(url.lastPathComponent) has no audio track")
        }
        let file = try AVAudioFile(forReading: wav)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw HaloError("Not enough memory for \(url.lastPathComponent)")
        }
        try file.read(into: buffer)
        guard buffer.frameLength > 0 else { throw HaloError("\(url.lastPathComponent) has no audio") }
        let left = peakBins(buffer, channels: [0]), right = peakBins(buffer, channels: [1])
        let scale = max(left.max() ?? 0, right.max() ?? 0, 0.0001)
        let all = zip(left, right).map { max($0, $1) / scale }
        return await AudioPreview(buffer: buffer, peaks: all, left: left.map { $0 / scale }, right: right.map { $0 / scale })
    }

    nonisolated private static func peakBins(_ buffer: AVAudioPCMBuffer, channels: [Int], bins: Int = 800) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength), perBin = max(frames / bins, 1)
        var result: [Float] = []
        result.reserveCapacity(bins)
        for bin in 0..<bins {
            let start = bin * perBin
            guard start < frames else { break }
            var peak: Float = 0
            for channel in channels where channel < Int(buffer.format.channelCount) {
                var value: Float = 0
                vDSP_maxmgv(data[channel] + start, 1, &value, vDSP_Length(min(perBin, frames - start)))
                peak = max(peak, value)
            }
            result.append(peak)
        }
        return result
    }

    // MARK: Playback

    func play(_ source: AVAudioPCMBuffer? = nil, from start: Double = 0, to end: Double? = nil) {
        stop()
        let source = source ?? buffer
        let rate = source.format.sampleRate
        let first = AVAudioFramePosition(start * rate)
        let last = AVAudioFramePosition((end ?? duration) * rate)
        guard let segment = Self.slice(source, from: first, to: last) else { return }
        if !engine.isRunning { try? engine.start() }
        offset = start
        let token = generation
        player.scheduleBuffer(segment) { [weak self] in
            DispatchQueue.main.async { if self?.generation == token { self?.stop() } }
        }
        player.play()
        playing = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        generation += 1
        player.stop()
        timer?.invalidate()
        timer = nil
        playing = false
        playhead = nil
    }

    func shutdown() {
        stop()
        engine.stop()
    }

    private func tick() {
        guard let nodeTime = player.lastRenderTime, let time = player.playerTime(forNodeTime: nodeTime) else { return }
        playhead = offset + Double(time.sampleTime) / time.sampleRate
    }

    // MARK: Buffer transforms (preview only)

    static func slice(_ source: AVAudioPCMBuffer, from start: AVAudioFramePosition, to end: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        let first = max(0, min(Int(start), Int(source.frameLength)))
        let last = max(first, min(Int(end), Int(source.frameLength)))
        guard last > first, let out = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: AVAudioFrameCount(last - first)),
              let src = source.floatChannelData, let dst = out.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(last - first)
        for channel in 0..<Int(source.format.channelCount) {
            dst[channel].update(from: src[channel] + first, count: last - first)
        }
        return out
    }

    func mixed(mono: Bool, left: Float, right: Float) -> AVAudioPCMBuffer {
        let out = Self.slice(buffer, from: 0, to: AVAudioFramePosition(buffer.frameLength)) ?? buffer
        guard let data = out.floatChannelData, out.format.channelCount == 2 else { return out }
        let n = vDSP_Length(out.frameLength)
        var l = left, r = right
        vDSP_vsmul(data[0], 1, &l, data[0], 1, n)
        vDSP_vsmul(data[1], 1, &r, data[1], 1, n)
        if mono {
            var half: Float = 0.5
            vDSP_vasm(data[0], 1, data[1], 1, &half, data[0], 1, n)
            data[1].update(from: data[0], count: Int(n))
        }
        return out
    }

    func bleeped(_ ranges: [ClosedRange<Double>]) -> AVAudioPCMBuffer {
        let out = Self.slice(buffer, from: 0, to: AVAudioFramePosition(buffer.frameLength)) ?? buffer
        guard let data = out.floatChannelData else { return out }
        let rate = out.format.sampleRate, frames = Int(out.frameLength)
        for range in MediaEdit.merge(ranges) {
            let first = max(0, Int(range.lowerBound * rate)), last = min(frames, Int(range.upperBound * rate))
            guard last > first else { continue }
            for frame in first..<last {
                let tone = Float(0.25 * sin(2 * .pi * 1000 * Double(frame) / rate))
                for channel in 0..<Int(out.format.channelCount) { data[channel][frame] = tone }
            }
        }
        return out
    }
}

/// Bars mirrored around the center; the selection is lit with the Halo spectrum, the rest dimmed.
struct WaveformView: View {
    let peaks: [Float]
    var selection: ClosedRange<Double> = 0...1
    var playhead: Double?

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let step = size.width / CGFloat(peaks.count)
            var lit = Path(), dim = Path()
            for (i, peak) in peaks.enumerated() {
                let x = CGFloat(i) * step, h = max(CGFloat(peak) * size.height * 0.92, 1)
                let bar = CGRect(x: x, y: (size.height - h) / 2, width: max(step * 0.6, 0.8), height: h)
                let position = Double(i) / Double(peaks.count)
                if selection.contains(position) { lit.addRect(bar) } else { dim.addRect(bar) }
            }
            context.fill(dim, with: .color(.white.opacity(0.18)))
            context.fill(lit, with: .linearGradient(Gradient(colors: [HaloPalette.ice, HaloPalette.cobalt, HaloPalette.indigo]),
                                                     startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
            if let playhead {
                let x = CGFloat(playhead) * size.width
                context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.white))
            }
        }
    }
}

enum MediaEdit {
    /// Overlapping ranges must be merged, or the ffmpeg enable expression sums to 2 and the bleep doubles in volume.
    static func merge(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var merged: [ClosedRange<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    static func bleepFilter(_ ranges: [ClosedRange<Double>]) -> String {
        let condition = merge(ranges)
            .map { String(format: "between(t,%.3f,%.3f)", $0.lowerBound, $0.upperBound) }
            .joined(separator: "+")
        return "[0:a]aformat=channel_layouts=stereo,volume=0:enable='\(condition)'[muted];"
            + "sine=frequency=1000:sample_rate=44100,aformat=channel_layouts=stereo,volume=0.25,"
            + "volume='\(condition)':eval=frame[tone];"
            + "[muted][tone]amix=inputs=2:duration=first:normalize=0[out]"
    }

    /// Mono sources are upmixed first so the same pan expression works for every input.
    static func panFilter(mono: Bool, left: Double, right: Double) -> String {
        let l = String(format: "%.3f", left), r = String(format: "%.3f", right)
        let half = String(format: "%.3f", left / 2), halfRight = String(format: "%.3f", right / 2)
        return mono
            ? "aformat=channel_layouts=stereo,pan=mono|c0=\(half)*c0+\(halfRight)*c1"
            : "aformat=channel_layouts=stereo,pan=stereo|c0=\(l)*c0|c1=\(r)*c1"
    }

    /// First and last bins louder than `threshold` (relative to the loudest), as normalized positions.
    static func silentBounds(_ peaks: [Float], threshold: Float = 0.03) -> ClosedRange<Double> {
        guard let first = peaks.firstIndex(where: { $0 > threshold }),
              let last = peaks.lastIndex(where: { $0 > threshold }) else { return 0...1 }
        return Double(first) / Double(peaks.count)...Double(last + 1) / Double(peaks.count)
    }

    /// Video keeps its picture stream untouched; only the audio is re-encoded.
    static func audioCodec(for url: URL) -> [String] {
        let ext = Catalog.normalize(url.pathExtension)
        if Catalog.row(for: url)?.category == .audio { return MediaEngine.codec(for: ext) }
        let audio: [String] = switch ext {
        case "webm": ["-c:a", "libopus"]
        case "avi": ["-c:a", "libmp3lame"]
        case "wmv": ["-c:a", "wmav2"]
        default: ["-c:a", "aac", "-b:a", "192k"]
        }
        return ["-c:v", "copy"] + audio
    }

    static func export(_ url: URL, suffix: String, _ args: [String]) async throws -> URL {
        let output = Output.url(for: url, ext: Catalog.normalize(url.pathExtension), suffix: suffix)
        try await MediaEngine.run(input: url, output: output, args)
        return output
    }

    static func time(_ seconds: Double) -> String {
        String(format: "%d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}
