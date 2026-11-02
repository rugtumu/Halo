import SwiftUI

@MainActor
enum MediaEditors {
    static func open(_ tool: Tool, url: URL) {
        Toast.show(.progress, "Loading audio…")
        Task {
            do {
                let media = try await AudioPreview.load(url)
                Toast.hide()
                let size = NSSize(width: 760, height: 560)
                switch tool {
                case .trim: EditorWindow.present(size: size) { TrimEditorView(media: media, url: url, close: $0) }
                case .channels: EditorWindow.present(size: size) { ChannelsEditorView(media: media, url: url, close: $0) }
                case .bleep: EditorWindow.present(size: size) { BleepEditorView(media: media, url: url, close: $0) }
                default: break
                }
            } catch {
                Toast.show(.failure, error.localizedDescription)
            }
        }
    }
}

private struct PlayButton: View {
    @ObservedObject var media: AudioPreview
    let title: String
    let action: () -> Void

    var body: some View {
        Button {
            media.playing ? media.stop() : action()
        } label: {
            Label(media.playing ? "Stop" : title, systemImage: media.playing ? "stop.fill" : "play.fill")
        }
    }
}

struct TrimEditorView: View {
    @ObservedObject var media: AudioPreview
    let url: URL
    let close: () -> Void
    @State private var start = 0.0
    @State private var end = 1.0
    @State private var trimSilence = false

    var body: some View {
        EditorChrome(title: "Trim", applyEnabled: start > 0.0005 || end < 0.9995, close: close, apply: apply) {
            VStack(spacing: 12) {
                HStack {
                    Text("Drag the ends to trim").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(MediaEdit.time((end - start) * media.duration)) selected").foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        WaveformView(peaks: media.peaks, selection: start...end,
                                     playhead: media.playhead.map { $0 / media.duration })
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(HaloPalette.cobalt, lineWidth: 2)
                            .frame(width: max((end - start) * geo.size.width, 1))
                            .offset(x: start * geo.size.width)
                            .allowsHitTesting(false)
                        handle(geo.size.width, isStart: true).offset(x: start * geo.size.width - 6)
                        handle(geo.size.width, isStart: false).offset(x: end * geo.size.width - 6)
                    }
                    .coordinateSpace(name: "wave")
                }
                .frame(height: 150)
                HStack {
                    Text("Start \(MediaEdit.time(start * media.duration))")
                    Spacer()
                    Text("End \(MediaEdit.time(end * media.duration))")
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            .padding(20)
        } controls: {
            HStack {
                Toggle("Trim silent ends automatically", isOn: $trimSilence).toggleStyle(.checkbox)
                Spacer()
                PlayButton(media: media, title: "Play Selected Range") {
                    media.play(from: start * media.duration, to: end * media.duration)
                }
            }
        }
        .onChange(of: trimSilence) { _, on in
            let bounds = on ? MediaEdit.silentBounds(media.peaks) : 0...1
            start = bounds.lowerBound
            end = bounds.upperBound
        }
        .onDisappear { media.shutdown() }
    }

    private func handle(_ width: CGFloat, isStart: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(HaloPalette.cobalt)
            .frame(width: 12)
            .overlay(Capsule().fill(.white).frame(width: 2, height: 24))
            .contentShape(Rectangle().inset(by: -8))
            .gesture(DragGesture(coordinateSpace: .named("wave")).onChanged { g in
                let value = min(max(g.location.x / width, 0), 1)
                if isStart { start = min(value, end - 0.01) } else { end = max(value, start + 0.01) }
                trimSilence = false
            })
    }

    private func apply() {
        let from = start * media.duration, length = (end - start) * media.duration, url = url
        close()
        Executor.job("Trimming…") {
            [try await MediaEdit.export(url, suffix: "trimmed",
                                        ["-ss", String(format: "%.3f", from), "-t", String(format: "%.3f", length)]
                                            + MediaEngine.codec(for: Catalog.normalize(url.pathExtension)))]
        }
    }
}

struct ChannelsEditorView: View {
    @ObservedObject var media: AudioPreview
    let url: URL
    let close: () -> Void
    @State private var mono = false
    @State private var left = 1.0
    @State private var right = 1.0

    var body: some View {
        EditorChrome(title: "Convert Audio Channels", close: close, apply: apply) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Output channel preview").font(.system(size: 12)).foregroundStyle(.secondary)
                if mono {
                    lane("Mono", zip(media.leftPeaks, media.rightPeaks).map { min(($0 * Float(left) + $1 * Float(right)) / 2, 1) })
                } else {
                    lane("Left", media.leftPeaks.map { min($0 * Float(left), 1) })
                    lane("Right", media.rightPeaks.map { min($0 * Float(right), 1) })
                }
            }
            .padding(20)
        } controls: {
            VStack(spacing: 8) {
                HStack {
                    Picker("", selection: $mono) {
                        Text("Mono").tag(true)
                        Text("Stereo").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                    Spacer()
                    PlayButton(media: media, title: "Play Output") {
                        media.play(media.mixed(mono: mono, left: Float(left), right: Float(right)))
                    }
                }
                SliderRow(title: "Left", value: $left, range: 0...1.5,
                          format: { "\(Int(($0 * 100).rounded()))%" }, neutral: 1)
                SliderRow(title: "Right", value: $right, range: 0...1.5,
                          format: { "\(Int(($0 * 100).rounded()))%" }, neutral: 1)
            }
        }
        .onDisappear { media.shutdown() }
    }

    private func lane(_ title: String, _ peaks: [Float]) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(HaloPalette.cobalt).frame(width: 44, alignment: .leading)
            WaveformView(peaks: peaks, playhead: media.playhead.map { $0 / media.duration })
        }
        .frame(maxHeight: 110)
    }

    private func apply() {
        let filter = MediaEdit.panFilter(mono: mono, left: left, right: right), url = url, mono = mono
        close()
        Executor.job("Converting channels…") {
            [try await MediaEdit.export(url, suffix: mono ? "mono" : "stereo", ["-af", filter] + MediaEdit.audioCodec(for: url))]
        }
    }
}

struct BleepEditorView: View {
    @ObservedObject var media: AudioPreview
    let url: URL
    let close: () -> Void
    @State private var bleeps: [ClosedRange<Double>] = []  // normalized
    @State private var drawing: ClosedRange<Double>?

    var body: some View {
        EditorChrome(title: "Bleep", applyEnabled: !bleeps.isEmpty, close: close, apply: apply) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text("Bleeps").foregroundStyle(.secondary)
                    Text("\(bleeps.count)").bold().foregroundStyle(HaloPalette.cobalt)
                }
                .font(.system(size: 12))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        WaveformView(peaks: media.peaks, playhead: media.playhead.map { $0 / media.duration })
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 3).onChanged { g in
                                let a = min(max(g.startLocation.x / geo.size.width, 0), 1)
                                let b = min(max(g.location.x / geo.size.width, 0), 1)
                                drawing = min(a, b)...max(a, b)
                            }.onEnded { _ in
                                if let drawing, drawing.upperBound - drawing.lowerBound > 0.002 { bleeps.append(drawing) }
                                drawing = nil
                            })
                        ForEach(Array((bleeps + (drawing.map { [$0] } ?? [])).enumerated()), id: \.offset) { index, range in
                            RoundedRectangle(cornerRadius: 6)
                                .fill(HaloPalette.cobalt.opacity(0.35))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HaloPalette.cobalt, lineWidth: 1.5))
                                .frame(width: max((range.upperBound - range.lowerBound) * geo.size.width, 3))
                                .offset(x: range.lowerBound * geo.size.width)
                                .onTapGesture { if index < bleeps.count { bleeps.remove(at: index) } }
                        }
                    }
                }
                .frame(height: 150)
                Text("Drag across the waveform to add a bleep. Click a bleep to remove it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        } controls: {
            HStack {
                Text("Preview").font(.system(size: 12, weight: .semibold)).foregroundStyle(HaloPalette.cobalt)
                Spacer()
                Button("Original") { media.play() }
                PlayButton(media: media, title: "With Bleeps") { media.play(media.bleeped(seconds)) }
                    .disabled(bleeps.isEmpty)
            }
        }
        .onDisappear { media.shutdown() }
    }

    private var seconds: [ClosedRange<Double>] {
        bleeps.map { ($0.lowerBound * media.duration)...($0.upperBound * media.duration) }
    }

    private func apply() {
        let filter = MediaEdit.bleepFilter(seconds), url = url
        close()
        Executor.job("Adding bleeps…") {
            [try await MediaEdit.export(url, suffix: "bleeped",
                                        ["-filter_complex", filter, "-map", "0:v?", "-map", "[out]"] + MediaEdit.audioCodec(for: url))]
        }
    }
}
