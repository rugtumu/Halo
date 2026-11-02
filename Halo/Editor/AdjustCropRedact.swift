import SwiftUI

struct AdjustEditorView: View {
    let doc: ImageDocument
    let close: () -> Void
    @State private var adjustments = ImageRender.Adjustments()
    @StateObject private var renderer = PreviewRenderer()
    @State private var showOriginal = false

    var body: some View {
        EditorChrome(title: "Edit Photo", applyEnabled: adjustments != .init(), close: close, apply: apply) {
            FittedImage(image: showOriginal ? doc.preview : (renderer.image ?? doc.preview))
                .overlay(alignment: .topTrailing) {
                    Text(showOriginal ? "Original" : "Hold to compare")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(12)
                        .onLongPressGesture(minimumDuration: 0, perform: {}, onPressingChanged: { showOriginal = $0 })
                }
        } controls: {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("Light")
                    SliderRow(title: "Exposure", value: $adjustments.exposure,
                              format: { String(format: "%+.2f EV", $0 * 2) })
                    SliderRow(title: "Brightness", value: $adjustments.brightness)
                    SliderRow(title: "Contrast", value: $adjustments.contrast)
                    SliderRow(title: "Highlights", value: $adjustments.highlights)
                    SliderRow(title: "Shadows", value: $adjustments.shadows)
                    sectionTitle("Color")
                    SliderRow(title: "Saturation", value: $adjustments.saturation)
                    SliderRow(title: "Vibrance", value: $adjustments.vibrance)
                    SliderRow(title: "Warmth", value: $adjustments.warmth)
                }
            }
            .frame(height: 250)
        }
        .onChange(of: adjustments) { _, value in
            let preview = doc.preview
            renderer.update { ImageRender.adjusted(preview, value) }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .bold)).foregroundStyle(HaloPalette.cobalt).padding(.top, 4)
    }

    private func apply() {
        let adjustments = adjustments
        doc.save("edited", close: close) { ImageRender.adjusted($0, adjustments) }
    }
}

enum CropAspect: String, CaseIterable, Identifiable {
    case free = "Free", square = "1:1", fourThree = "4:3", threeTwo = "3:2", wide = "16:9", tall = "9:16"
    var id: String { rawValue }
    var ratio: CGFloat? {
        switch self {
        case .free: nil
        case .square: 1
        case .fourThree: 4 / 3
        case .threeTwo: 3 / 2
        case .wide: 16 / 9
        case .tall: 9 / 16
        }
    }
}

struct CropEditorView: View {
    let doc: ImageDocument
    let close: () -> Void
    @State private var image: CGImage
    @State private var turns = 0
    @State private var rect = CropMath.fitted(ratio: nil)
    @State private var aspect = CropAspect.free
    @State private var dragStart: CGRect?

    init(doc: ImageDocument, close: @escaping () -> Void) {
        self.doc = doc
        self.close = close
        _image = State(initialValue: doc.preview)
    }

    /// Pixel aspect → normalized aspect for the current (possibly rotated) image.
    private var ratio: CGFloat? {
        aspect.ratio.map { $0 / (CGFloat(image.width) / CGFloat(image.height)) }
    }

    var body: some View {
        EditorChrome(title: "Crop", close: close, apply: apply) {
            FittedImage(image: image) { size in overlay(size) }
        } controls: {
            HStack {
                Picker("", selection: $aspect) {
                    ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 380)
                Spacer()
                Button { rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }
                Button { rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }
                Button("Reset") {
                    image = doc.preview
                    turns = 0
                    aspect = .free
                    rect = CropMath.fitted(ratio: nil)
                }
            }
        }
        .onChange(of: aspect) { rect = CropMath.fitted(ratio: ratio) }
    }

    private func overlay(_ size: CGSize) -> some View {
        let r = denormalized(rect, in: size)
        return ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRect(r)
            }
            .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Path { p in
                for i in 1...2 {
                    let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                    p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }
            .stroke(.white.opacity(0.3), lineWidth: 0.5)
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(.white, lineWidth: 1.5)
                .contentShape(Rectangle())
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .gesture(drag(.move, size))

            ForEach([(CropHandle.topLeft, CGPoint(x: r.minX, y: r.minY)), (.topRight, CGPoint(x: r.maxX, y: r.minY)),
                     (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.bottomRight, CGPoint(x: r.maxX, y: r.maxY))],
                    id: \.0) { handle, point in
                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .shadow(radius: 2)
                    .position(point)
                    .gesture(drag(handle, size))
            }
        }
    }

    private func drag(_ handle: CropHandle, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if dragStart == nil { dragStart = rect }
                rect = CropMath.update(dragStart ?? rect, handle: handle,
                                       dx: gesture.translation.width / size.width,
                                       dy: gesture.translation.height / size.height, ratio: ratio)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func rotate(clockwise: Bool) {
        image = ImageRender.rotate(image, clockwise: clockwise)
        turns = (turns + (clockwise ? 1 : 3)) % 4
        rect = CropMath.fitted(ratio: ratio)
    }

    private func apply() {
        let turns = turns, rect = rect
        doc.save("cropped", close: close) { full in
            var image = full
            for _ in 0..<turns { image = ImageRender.rotate(image, clockwise: true) }
            return ImageRender.crop(image, to: rect)
        }
    }
}

struct RedactEditorView: View {
    let doc: ImageDocument
    let close: () -> Void
    @State private var regions: [CGRect] = []
    @State private var style = ImageRender.RedactStyle.pixelate
    @State private var drawing: CGRect?
    @StateObject private var renderer = PreviewRenderer()

    var body: some View {
        EditorChrome(title: "Redact", applyEnabled: !regions.isEmpty, close: close, apply: apply) {
            FittedImage(image: renderer.image ?? doc.preview) { size in
                ZStack(alignment: .topLeading) {
                    Color.clear.contentShape(Rectangle())
                    if let drawing {
                        let r = denormalized(drawing, in: size)
                        Rectangle()
                            .strokeBorder(.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                    }
                }
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { g in
                        let a = normalized(g.startLocation, in: size), b = normalized(g.location, in: size)
                        drawing = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                    }
                    .onEnded { _ in
                        if let drawing, drawing.width > 0.005, drawing.height > 0.005 { regions.append(drawing) }
                        drawing = nil
                    })
            }
        } controls: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("", selection: $style) {
                        ForEach(ImageRender.RedactStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    Spacer()
                    Button("Undo") { _ = regions.popLast() }.disabled(regions.isEmpty)
                    Button("Clear") { regions.removeAll() }.disabled(regions.isEmpty)
                }
                Text("Drag over what you want to hide. Black Box is the only style that can't be reversed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: regions) { render() }
        .onChange(of: style) { render() }
    }

    private func render() {
        guard !regions.isEmpty else { return renderer.clear() }
        let preview = doc.preview, regions = regions, style = style
        renderer.update { ImageRender.redact(preview, regions: regions, style: style) }
    }

    private func apply() {
        let regions = regions, style = style
        doc.save("redacted", close: close) { ImageRender.redact($0, regions: regions, style: style) }
    }
}
