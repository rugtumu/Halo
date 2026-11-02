import AppKit
import ImageIO
import SwiftUI

struct AnnotateEditorView: View {
    let doc: ImageDocument
    let close: () -> Void

    private static let palette: [NSColor] = [
        NSColor(HaloPalette.cobalt), NSColor(HaloPalette.ice), .systemYellow, .systemGreen, .systemBlue, .white, .black,
    ]

    @State private var marks: [ImageRender.Mark] = []
    @State private var current: ImageRender.Mark?
    @State private var tool = ImageRender.MarkTool.arrow
    @State private var color = palette[0]
    @State private var width = 0.006
    @State private var text = "Text"

    var body: some View {
        EditorChrome(title: "Annotate", applyEnabled: !marks.isEmpty, close: close, apply: apply) {
            FittedImage(image: doc.preview) { size in
                Canvas { context, canvasSize in
                    context.withCGContext { cg in
                        ImageRender.draw(marks + (current.map { [$0] } ?? []), in: cg, size: canvasSize)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in draw(g, size) }
                    .onEnded { _ in
                        if let current { marks.append(current) }
                        current = nil
                    })
            }
        } controls: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Picker("", selection: $tool) {
                        ForEach(ImageRender.MarkTool.allCases) { Image(systemName: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 230)
                    HStack(spacing: 6) {
                        ForEach(Self.palette, id: \.self) { swatch in
                            Circle()
                                .fill(Color(nsColor: swatch))
                                .frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(.white, lineWidth: swatch == color ? 2 : 0.5))
                                .onTapGesture { color = swatch }
                        }
                    }
                    Spacer()
                    Button("Undo") { _ = marks.popLast() }.disabled(marks.isEmpty)
                    Button("Clear") { marks.removeAll() }.disabled(marks.isEmpty)
                }
                HStack(spacing: 14) {
                    SliderRow(title: "Size", value: $width, range: 0.002...0.02,
                              format: { "\(Int(($0 * 1000).rounded()))" }, neutral: 0.006)
                    if tool == .text {
                        TextField("Text", text: $text).textFieldStyle(.roundedBorder).frame(width: 180)
                    }
                }
            }
        }
    }

    private func draw(_ gesture: DragGesture.Value, _ size: CGSize) {
        let point = normalized(gesture.location, in: size)
        if current == nil {
            current = ImageRender.Mark(tool: tool, points: [normalized(gesture.startLocation, in: size)],
                                       color: color.cgColor, width: width, text: text)
        }
        switch tool {
        case .pen, .highlighter: current?.points.append(point)
        case .arrow, .box: current?.points = [current?.points.first ?? point, point]
        case .text: current?.points = [point]
        }
    }

    private func apply() {
        let marks = marks
        doc.save("annotated", close: close) { ImageRender.annotate($0, marks: marks) }
    }
}

private struct BackdropPreset: Identifiable {
    let id: String
    let colors: [NSColor]

    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static let all: [BackdropPreset] = [
        BackdropPreset(id: "halo", colors: [NSColor(HaloPalette.ice), NSColor(HaloPalette.cobalt), NSColor(HaloPalette.indigo)]),
        BackdropPreset(id: "sunset", colors: [hex(0xFB923C), hex(0xEC4899)]),
        BackdropPreset(id: "peach", colors: [hex(0xFED7AA), hex(0xFB7185)]),
        BackdropPreset(id: "ocean", colors: [hex(0x22D3EE), hex(0x2563EB)]),
        BackdropPreset(id: "sky", colors: [hex(0xE0F2FE), hex(0x7DD3FC)]),
        BackdropPreset(id: "mint", colors: [hex(0xA7F3D0), hex(0x10B981)]),
        BackdropPreset(id: "dusk", colors: [hex(0x6D28D9), hex(0x1E1B4B)]),
        BackdropPreset(id: "graphite", colors: [hex(0x3F3F46), hex(0x18181B)]),
        BackdropPreset(id: "snow", colors: [.white]),
        BackdropPreset(id: "ink", colors: [.black]),
    ]
}

private enum BackdropAspect: String, CaseIterable, Identifiable {
    case auto = "Auto", square = "1:1", fourThree = "4:3", wide = "16:9", story = "9:16"
    var id: String { rawValue }
    var ratio: Double? {
        switch self {
        case .auto: nil
        case .square: 1
        case .fourThree: 4.0 / 3
        case .wide: 16.0 / 9
        case .story: 9.0 / 16
        }
    }
}

struct BackgroundEditorView: View {
    let doc: ImageDocument
    let close: () -> Void
    @State private var preset = BackdropPreset.all[0].id
    @State private var customImage: CGImage?
    @State private var padding = 0.12
    @State private var radius = 0.03
    @State private var shadow = true
    @State private var aspect = BackdropAspect.auto
    @StateObject private var renderer = PreviewRenderer()

    private var backdrop: ImageRender.Backdrop {
        let colors = BackdropPreset.all.first { $0.id == preset }?.colors.map(\.cgColor) ?? [CGColor(gray: 1, alpha: 1)]
        return ImageRender.Backdrop(colors: colors, image: preset == "custom" ? customImage : nil,
                                    padding: padding, radius: radius, shadow: shadow, aspect: aspect.ratio)
    }

    var body: some View {
        EditorChrome(title: "Add BG", close: close, apply: apply) {
            FittedImage(image: renderer.image ?? doc.preview)
        } controls: {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(BackdropPreset.all) { item in
                            swatch(selected: preset == item.id) {
                                LinearGradient(colors: item.colors.map { Color(nsColor: $0) },
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            }
                            .onTapGesture { preset = item.id }
                        }
                        swatch(selected: preset == "custom") {
                            if let customImage {
                                Image(decorative: customImage, scale: 1).resizable().scaledToFill()
                            } else {
                                Image(systemName: "photo.badge.plus").font(.system(size: 15)).frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .onTapGesture(perform: chooseImage)
                    }
                    .padding(2)
                }
                SliderRow(title: "Padding", value: $padding, range: 0...0.3,
                          format: { "\(Int(($0 * 100).rounded()))%" }, neutral: 0.12)
                SliderRow(title: "Corners", value: $radius, range: 0...0.12,
                          format: { "\(Int(($0 * 100).rounded()))" }, neutral: 0.03)
                HStack {
                    Toggle("Shadow", isOn: $shadow).toggleStyle(.checkbox)
                    Spacer()
                    Picker("", selection: $aspect) {
                        ForEach(BackdropAspect.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 300)
                }
            }
        }
        .onChange(of: backdrop, initial: true) { _, value in
            let preview = doc.preview
            renderer.update { ImageRender.addBackground(preview, value) }
        }
    }

    private func swatch<Fill: View>(selected: Bool, @ViewBuilder fill: () -> Fill) -> some View {
        fill()
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? HaloPalette.cobalt : .white.opacity(0.2), lineWidth: selected ? 2 : 1))
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let image = try? ImageEngine.load(url) else { return }
        let long = CGFloat(max(image.width, image.height))
        customImage = long > 3000 ? ImageEngine.redraw(image, scale: 3000 / long) : image
        preset = "custom"
    }

    private func apply() {
        let backdrop = backdrop
        doc.save("background", close: close) { ImageRender.addBackground($0, backdrop) }
    }
}

enum ImageMetadata {
    struct Group: Identifiable {
        let name: String
        let rows: [(key: String, value: String)]
        var id: String { name }
    }

    /// Top-level properties go in "General"; nested dictionaries ({Exif}, {GPS}, …) become their own groups.
    static func groups(for url: URL) -> [Group] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return [] }
        var general: [(String, String)] = []
        var nested: [Group] = []
        for (key, value) in props.sorted(by: { $0.key < $1.key }) {
            if let dict = value as? [String: Any] {
                let rows = dict.sorted { $0.key < $1.key }.map { ($0.key, describe($0.value)) }
                if !rows.isEmpty { nested.append(Group(name: key.trimmingCharacters(in: CharacterSet(charactersIn: "{}")), rows: rows)) }
            } else {
                general.append((key, describe(value)))
            }
        }
        return (general.isEmpty ? [] : [Group(name: "General", rows: general)]) + nested
    }

    private static func describe(_ value: Any) -> String {
        switch value {
        case let data as Data: "(\(data.count) bytes)"
        case let array as [Any]: array.map(describe).joined(separator: ", ")
        default: "\(value)"
        }
    }
}

struct MetadataView: View {
    let doc: ImageDocument
    let close: () -> Void
    private let groups: [ImageMetadata.Group]

    init(doc: ImageDocument, close: @escaping () -> Void) {
        self.doc = doc
        self.close = close
        groups = ImageMetadata.groups(for: doc.url)
    }

    var body: some View {
        EditorChrome(title: "Metadata", applyTitle: "Remove All", applyEnabled: !groups.isEmpty, close: close, apply: removeAll) {
            if groups.isEmpty {
                Text("No metadata").foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(groups) { group in
                        Section(group.name) {
                            ForEach(group.rows, id: \.key) { row in
                                HStack(alignment: .top) {
                                    Text(row.key).foregroundStyle(.secondary)
                                    Spacer(minLength: 16)
                                    Text(row.value).multilineTextAlignment(.trailing).textSelection(.enabled)
                                }
                                .font(.system(size: 12))
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        } controls: {
            if groups.contains(where: { $0.name == "GPS" }) {
                Label("This photo contains location data.", systemImage: "location.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HaloPalette.cobalt)
            }
        }
    }

    private func removeAll() {
        let url = doc.url
        close()
        Executor.job("Removing metadata…") { [try await ToolEngine.stripImageMetadata(url)] }
    }
}
