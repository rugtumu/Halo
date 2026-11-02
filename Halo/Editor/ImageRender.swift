import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Pure image operations shared by the editor previews (small image) and Apply (full resolution).
/// Every geometric input is normalized with a top-left origin so the same edit works at any size.
enum ImageRender {
    static let context = CIContext(options: [.cacheIntermediates: false])

    static func render(_ image: CIImage, extent: CGRect) -> CGImage? {
        context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    // MARK: Light & color

    struct Adjustments: Equatable {
        var exposure = 0.0, brightness = 0.0, contrast = 0.0, highlights = 0.0, shadows = 0.0
        var saturation = 0.0, vibrance = 0.0, warmth = 0.0
    }

    static func adjusted(_ source: CGImage, _ a: Adjustments) -> CGImage? {
        let input = CIImage(cgImage: source)
        var image = input
        if a.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = image
            f.ev = Float(a.exposure * 2)
            image = f.outputImage ?? image
        }
        if a.brightness != 0 || a.contrast != 0 || a.saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.brightness = Float(a.brightness * 0.25)
            f.contrast = Float(1 + a.contrast * 0.5)
            f.saturation = Float(1 + a.saturation)
            image = f.outputImage ?? image
        }
        if a.highlights < 0 || a.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = image
            f.highlightAmount = Float(1 + min(a.highlights, 0))
            f.shadowAmount = Float(a.shadows)
            image = f.outputImage ?? image
        }
        if a.highlights > 0 {
            // CIHighlightShadowAdjust can only pull highlights down; lift them with a tone curve.
            let f = CIFilter.toneCurve()
            f.inputImage = image
            f.point3 = CGPoint(x: 0.75, y: 0.75 + 0.15 * a.highlights)
            image = f.outputImage ?? image
        }
        if a.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = image
            f.amount = Float(a.vibrance)
            image = f.outputImage ?? image
        }
        if a.warmth != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 + 2500 * a.warmth, y: 0)
            image = f.outputImage ?? image
        }
        return render(image, extent: input.extent)
    }

    // MARK: Crop & rotate

    static func pixelRect(_ rect: CGRect, width: Int, height: Int) -> CGRect {
        let w = CGFloat(width), h = CGFloat(height)
        return CGRect(x: (rect.minX * w).rounded(), y: (rect.minY * h).rounded(),
                      width: (rect.width * w).rounded(), height: (rect.height * h).rounded())
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// CGImage cropping works in top-left pixel space, matching the normalized rect.
    static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        image.cropping(to: pixelRect(rect, width: image.width, height: image.height))
    }

    static func rotate(_ image: CGImage, clockwise: Bool) -> CGImage {
        let width = image.height, height = image.width
        guard let ctx = ImageEngine.makeContext(width: width, height: height) else { return image }
        if clockwise {
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.rotate(by: -.pi / 2)
        } else {
            ctx.translateBy(x: CGFloat(width), y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    // MARK: Redact

    enum RedactStyle: String, CaseIterable, Identifiable {
        case pixelate = "Pixelate", blur = "Blur", black = "Black Box"
        var id: String { rawValue }
    }

    static func redact(_ source: CGImage, regions: [CGRect], style: RedactStyle) -> CGImage? {
        let base = CIImage(cgImage: source)
        let w = CGFloat(source.width), h = CGFloat(source.height), long = max(w, h)
        let effect: CIImage
        switch style {
        case .pixelate:
            let f = CIFilter.pixellate()
            f.inputImage = base.clampedToExtent()
            f.scale = Float(long / 45)
            f.center = .zero
            effect = f.outputImage ?? base
        case .blur:
            effect = base.clampedToExtent().applyingGaussianBlur(sigma: Double(long / 50))
        case .black:
            effect = CIImage(color: .black)
        }
        var output = base
        for region in regions {
            // Core Image is bottom-left origin.
            let rect = CGRect(x: region.minX * w, y: (1 - region.maxY) * h, width: region.width * w, height: region.height * h)
            output = effect.cropped(to: rect).composited(over: output)
        }
        return render(output, extent: base.extent)
    }

    // MARK: Background

    /// Fractions are relative to the image's long edge so preview and export match.
    struct Backdrop: Equatable {
        var colors: [CGColor]
        var image: CGImage?
        var padding: Double
        var radius: Double
        var shadow: Bool
        var aspect: Double?
    }

    static func canvasSize(imageWidth: Int, imageHeight: Int, padding: Double, aspect: Double?) -> CGSize {
        let long = CGFloat(max(imageWidth, imageHeight)), pad = CGFloat(padding) * long
        var width = CGFloat(imageWidth) + 2 * pad, height = CGFloat(imageHeight) + 2 * pad
        if let aspect {
            if width / height < aspect { width = height * aspect } else { height = width / aspect }
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    static func addBackground(_ source: CGImage, _ b: Backdrop) -> CGImage? {
        let size = canvasSize(imageWidth: source.width, imageHeight: source.height, padding: b.padding, aspect: b.aspect)
        guard let ctx = ImageEngine.makeContext(width: Int(size.width), height: Int(size.height)) else { return nil }
        let canvas = CGRect(origin: .zero, size: size)

        if let image = b.image {
            let scale = max(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
            let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
            ctx.draw(image, in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
        } else if b.colors.count == 1 {
            ctx.setFillColor(b.colors[0])
            ctx.fill(canvas)
        } else if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                            colors: b.colors as CFArray, locations: nil) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        }

        let long = CGFloat(max(source.width, source.height))
        let rect = CGRect(x: (size.width - CGFloat(source.width)) / 2, y: (size.height - CGFloat(source.height)) / 2,
                          width: CGFloat(source.width), height: CGFloat(source.height))
        let radius = min(CGFloat(b.radius) * long, min(rect.width, rect.height) / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        if b.shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -long * 0.015), blur: long * 0.05,
                          color: CGColor(gray: 0, alpha: 0.45))
        }
        // A transparency layer lets the shadow follow the clipped image, including transparent PNGs.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(source, in: rect)
        ctx.endTransparencyLayer()
        return ctx.makeImage()
    }

    // MARK: Annotate

    enum MarkTool: String, CaseIterable, Identifiable {
        case pen, highlighter, arrow, box, text
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .pen: "pencil.tip"
            case .highlighter: "highlighter"
            case .arrow: "arrow.up.right"
            case .box: "rectangle"
            case .text: "textformat"
            }
        }
    }

    struct Mark {
        var tool: MarkTool
        var points: [CGPoint]  // normalized
        var color: CGColor
        var width: CGFloat     // fraction of the image's short side
        var text = ""
    }

    /// Draws into a y-down context of the given size (a SwiftUI Canvas, or a flipped bitmap).
    static func draw(_ marks: [Mark], in ctx: CGContext, size: CGSize) {
        let short = min(size.width, size.height)
        for mark in marks {
            let points = mark.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            guard let first = points.first, let last = points.last else { continue }
            let lineWidth = mark.width * short
            ctx.saveGState()
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(mark.color)
            ctx.setLineWidth(lineWidth)
            switch mark.tool {
            case .pen:
                ctx.addLines(between: points)
                ctx.strokePath()
            case .highlighter:
                ctx.setStrokeColor(mark.color.copy(alpha: 0.35) ?? mark.color)
                ctx.setLineWidth(lineWidth * 4)
                ctx.setLineCap(.butt)
                ctx.addLines(between: points)
                ctx.strokePath()
            case .arrow:
                let angle = atan2(last.y - first.y, last.x - first.x), head = lineWidth * 4 + 6
                ctx.move(to: first)
                ctx.addLine(to: last)
                for side in [-1.0, 1.0] {
                    ctx.move(to: last)
                    ctx.addLine(to: CGPoint(x: last.x - head * cos(angle + side * 0.45),
                                            y: last.y - head * sin(angle + side * 0.45)))
                }
                ctx.strokePath()
            case .box:
                ctx.stroke(CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                                  width: abs(last.x - first.x), height: abs(last.y - first.y)))
            case .text:
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                let font = NSFont.systemFont(ofSize: max(lineWidth * 7, 6), weight: .bold)
                (mark.text as NSString).draw(at: first, withAttributes: [
                    .font: font, .foregroundColor: NSColor(cgColor: mark.color) ?? .white,
                ])
                NSGraphicsContext.restoreGraphicsState()
            }
            ctx.restoreGState()
        }
    }

    static func annotate(_ source: CGImage, marks: [Mark]) -> CGImage? {
        let w = source.width, h = source.height
        guard let ctx = ImageEngine.makeContext(width: w, height: h) else { return nil }
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        draw(marks, in: ctx, size: CGSize(width: w, height: h))
        return ctx.makeImage()
    }
}

enum CropHandle { case move, topLeft, topRight, bottomLeft, bottomRight }

/// Crop rectangle math in normalized coordinates; `ratio` is width/height in normalized units.
enum CropMath {
    static let minSide: CGFloat = 0.05

    static func update(_ start: CGRect, handle: CropHandle, dx: CGFloat, dy: CGFloat, ratio: CGFloat?) -> CGRect {
        if handle == .move {
            return CGRect(x: min(max(start.minX + dx, 0), 1 - start.width),
                          y: min(max(start.minY + dy, 0), 1 - start.height),
                          width: start.width, height: start.height)
        }
        let left = handle == .topLeft || handle == .bottomLeft
        let top = handle == .topLeft || handle == .topRight
        var minX = start.minX, minY = start.minY, maxX = start.maxX, maxY = start.maxY
        if left { minX = min(max(minX + dx, 0), maxX - minSide) } else { maxX = max(min(maxX + dx, 1), minX + minSide) }
        if top { minY = min(max(minY + dy, 0), maxY - minSide) } else { maxY = max(min(maxY + dy, 1), minY + minSide) }

        if let ratio {
            var width = maxX - minX, height = width / ratio
            let available = top ? maxY : 1 - minY
            if height > available {
                height = available
                width = height * ratio
            }
            if left { minX = maxX - width } else { maxX = minX + width }
            if top { minY = maxY - height } else { maxY = minY + height }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Largest centered rect with the given normalized ratio.
    static func fitted(ratio: CGFloat?) -> CGRect {
        guard let ratio else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let width = ratio >= 1 ? 1 : ratio, height = ratio >= 1 ? 1 / ratio : 1
        return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }
}
