import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ImageEngine {
    static func type(for ext: String) -> UTType? {
        switch ext {
        case "jpg": .jpeg
        case "png": .png
        case "heic": .heic
        case "tiff": .tiff
        case "bmp": .bmp
        case "webp": .webP
        case "avif": UTType("public.avif")
        case "pdf": .pdf
        default: nil
        }
    }

    static func canWriteNatively(_ ext: String) -> Bool {
        if ext == "pdf" { return true }
        guard let type = type(for: ext) else { return false }
        return writableTypes.contains(type.identifier)
    }

    /// Asked once: the wheel checks this for every target of every dragged file.
    private static let writableTypes = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])

    /// ImageIO covers most targets; WEBP/AVIF encoding falls back to ffmpeg when the OS can't write them.
    static func canWrite(_ ext: String) -> Bool {
        canWriteNatively(ext) || (Binaries.ffmpeg != nil && ["webp", "avif"].contains(ext))
    }

    /// Full-resolution image with EXIF orientation applied.
    static func load(_ url: URL) throws -> CGImage {
        if Catalog.normalize(url.pathExtension) == "svg" { return try rasterizeSVG(url) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw HaloError("Can't read \(url.lastPathComponent)")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw HaloError("Can't decode \(url.lastPathComponent)")
        }
        return image
    }

    private static func rasterizeSVG(_ url: URL) throws -> CGImage {
        guard let image = NSImage(contentsOf: url), image.size.width > 0 else {
            throw HaloError("Can't read \(url.lastPathComponent)")
        }
        let width = Int(image.size.width * 2), height = Int(image.size.height * 2)
        guard let context = makeContext(width: width, height: height) else { throw HaloError("Out of memory") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let result = context.makeImage() else { throw HaloError("Can't render \(url.lastPathComponent)") }
        return result
    }

    static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Redraws at a new size; also used to flatten transparency onto white for JPG/BMP.
    static func redraw(_ image: CGImage, scale: CGFloat = 1, background: CGColor? = nil) -> CGImage {
        let width = max(Int(CGFloat(image.width) * scale), 1), height = max(Int(CGFloat(image.height) * scale), 1)
        guard let context = makeContext(width: width, height: height) else { return image }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if let background {
            context.setFillColor(background)
            context.fill(rect)
        }
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    static func write(_ image: CGImage, to url: URL, ext: String, quality: Double = 0.9,
                      properties: [CFString: Any] = [:]) async throws {
        if ext == "pdf" {
            let document = PDFDocument()
            guard let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))) else {
                throw HaloError("Can't create PDF page")
            }
            document.insert(page, at: 0)
            guard document.write(to: url) else { throw HaloError("Can't write \(url.lastPathComponent)") }
            return
        }

        let pixels = ["jpg", "bmp"].contains(ext) ? redraw(image, background: CGColor(gray: 1, alpha: 1)) : image
        if canWriteNatively(ext), let type = type(for: ext) {
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                throw HaloError("Can't write \(ext.uppercased())")
            }
            var options = properties
            options[kCGImageDestinationLossyCompressionQuality] = quality
            CGImageDestinationAddImage(destination, pixels, options as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw HaloError("Can't write \(url.lastPathComponent)") }
            return
        }

        guard let ffmpeg = Binaries.ffmpeg else { throw HaloError("ffmpeg is required for \(ext.uppercased())") }
        let temp = try Output.tempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let png = temp.appendingPathComponent("frame.png")
        try await write(pixels, to: png, ext: "png")
        let codec = ext == "webp"
            ? ["-c:v", "libwebp", "-quality", "\(Int(quality * 100))"]
            : ["-c:v", "libaom-av1", "-still-picture", "1", "-crf", "\(Int(50 - quality * 30))", "-cpu-used", "6"]
        try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", png.path] + codec + [url.path])
    }

    static func convert(_ url: URL, to ext: String) async throws -> URL {
        let image = try load(url)
        let output = Output.url(for: url, ext: ext)
        try await write(image, to: output, ext: ext)
        return output
    }
}
