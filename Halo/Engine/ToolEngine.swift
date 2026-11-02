import AppKit
import ImageIO
import PDFKit

enum ResizeOption {
    case scale(Double)
    case longEdge(Int)
    case height(Int)
}

enum ToolEngine {
    static func tools(for url: URL) -> [Tool] {
        guard let row = Catalog.row(for: url) else { return [] }
        let hasFFmpeg = Binaries.ffmpeg != nil
        switch row.category {
        case .image: return row.source == "svg" ? [] : Tool.defaults(for: .image)
        case .video:
            guard hasFFmpeg else { return [] }
            // GIFs have no audio track for the audio editors to work on.
            return Tool.defaults(for: .video).filter { row.source != "gif" || !$0.isMediaEditor }
        case .audio: return hasFFmpeg ? Tool.defaults(for: .audio) : []
        case .document: return row.source == "pdf" ? Tool.defaults(for: .document) : []
        default: return []
        }
    }

    @MainActor
    static func run(_ tool: Tool, on urls: [URL]) async throws -> [URL] {
        var option: ResizeOption?
        if tool == .resize {
            let isVideo = urls.contains { Catalog.row(for: $0)?.category == .video }
            guard let chosen = ResizePrompt.ask(video: isVideo) else { return [] }
            option = chosen
        }
        var results: [URL] = []
        for url in urls { results.append(try await apply(tool, to: url, option: option)) }
        return results
    }

    private static func apply(_ tool: Tool, to url: URL, option: ResizeOption?) async throws -> URL {
        let ext = Catalog.normalize(url.pathExtension)
        switch (tool, Catalog.row(for: url)?.category) {
        case (.compress, .image): return try await compressImage(url, ext: ext)
        case (.resize, .image): return try await resizeImage(url, ext: ext, option: option)
        case (.metadata, .image): return try await stripImageMetadata(url)
        case (.compress, .document): return try compressPDF(url)
        case (.compress, .video):
            let output = Output.url(for: url, ext: "mp4", suffix: "compressed")
            try await MediaEngine.run(input: url, output: output, [
                "-c:v", "hevc_videotoolbox", "-q:v", "50", "-tag:v", "hvc1",
                "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart",
            ])
            return try keepIfSmaller(output, than: url)
        case (.resize, .video):
            guard case .height(let height) = option else { throw HaloError("Pick a video size") }
            let output = Output.url(for: url, ext: ext, suffix: "\(height)p")
            try await MediaEngine.run(input: url, output: output, [
                "-vf", "scale=-2:\(height)", "-c:v", "h264_videotoolbox", "-q:v", "65", "-c:a", "copy",
            ])
            return output
        case (.metadata, .video), (.metadata, .audio):
            let output = Output.url(for: url, ext: ext, suffix: "clean")
            try await MediaEngine.run(input: url, output: output, ["-map_metadata", "-1", "-map_chapters", "-1", "-c", "copy"])
            return output
        case (.compress, .audio):
            return try await compressAudio(url, ext: ext)
        default:
            throw HaloError("\(tool.title) isn't available for \(url.lastPathComponent)")
        }
    }

    private static func keepIfSmaller(_ output: URL, than source: URL) throws -> URL {
        guard Output.size(output) < Output.size(source) else {
            try? FileManager.default.removeItem(at: output)
            throw HaloError("\(source.lastPathComponent) is already well optimized")
        }
        return output
    }

    private static func compressImage(_ url: URL, ext: String) async throws -> URL {
        let image = try ImageEngine.load(url)
        let output = Output.url(for: url, ext: ext, suffix: "compressed")
        switch ext {
        case "jpg", "heic", "webp", "avif":
            try await ImageEngine.write(image, to: output, ext: ext, quality: 0.6)
        case "png":
            try await ImageEngine.write(image, to: output, ext: ext)
        case "tiff":
            try await ImageEngine.write(image, to: output, ext: ext, properties: [
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5], // LZW
            ])
        default:
            throw HaloError("\(ext.uppercased()) is uncompressed — convert it to PNG or JPG instead")
        }
        return try keepIfSmaller(output, than: url)
    }

    private static func resizeImage(_ url: URL, ext: String, option: ResizeOption?) async throws -> URL {
        let image = try ImageEngine.load(url)
        let longEdge = CGFloat(max(image.width, image.height))
        let scale: CGFloat
        let label: String
        switch option {
        case .scale(let factor):
            scale = factor
            label = "\(Int(factor * 100))%"
        case .longEdge(let pixels):
            scale = min(CGFloat(pixels) / longEdge, 1) // never upscale
            label = "\(pixels)px"
        default:
            throw HaloError("Pick an image size")
        }
        let output = Output.url(for: url, ext: ext, suffix: label)
        try await ImageEngine.write(ImageEngine.redraw(image, scale: scale), to: output, ext: ext)
        return output
    }

    /// Lossless where ImageIO can copy the encoded data; re-encodes at high quality otherwise.
    static func stripImageMetadata(_ url: URL) async throws -> URL {
        let ext = Catalog.normalize(url.pathExtension)
        let output = Output.url(for: url, ext: ext, suffix: "clean")
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source),
           let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) {
            let options: [CFString: Any] = [
                kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
                kCGImageDestinationMergeMetadata: false,
                kCGImageMetadataShouldExcludeXMP: true,
                kCGImageMetadataShouldExcludeGPS: true,
            ]
            if CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil) { return output }
            try? FileManager.default.removeItem(at: output)
        }
        try await ImageEngine.write(try ImageEngine.load(url), to: output, ext: ext, quality: 0.95)
        return output
    }

    private static func compressPDF(_ url: URL) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw HaloError("Can't open \(url.lastPathComponent)") }
        let output = Output.url(for: url, ext: "pdf", suffix: "compressed")
        let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
        guard document.write(to: output, withOptions: options) else { throw HaloError("Can't write \(output.lastPathComponent)") }
        return try keepIfSmaller(output, than: url)
    }

    private static func compressAudio(_ url: URL, ext: String) async throws -> URL {
        // Lossy sources keep their format at a lower bitrate; lossless ones become AAC.
        let (outExt, codec): (String, [String]) = switch ext {
        case "mp3": ("mp3", ["-c:a", "libmp3lame", "-b:a", "128k"])
        case "ogg": ("ogg", ["-c:a", "libvorbis", "-q:a", "3"])
        case "opus": ("opus", ["-c:a", "libopus", "-b:a", "96k"])
        case "wma": ("wma", ["-c:a", "wmav2", "-b:a", "128k"])
        case "m4a": ("m4a", ["-c:a", "aac", "-b:a", "128k"])
        default: ("m4a", ["-c:a", "aac", "-b:a", "192k"])
        }
        let output = Output.url(for: url, ext: outExt, suffix: "compressed")
        try await MediaEngine.run(input: url, output: output, ["-vn"] + codec)
        return try keepIfSmaller(output, than: url)
    }
}

@MainActor
enum ResizePrompt {
    static func ask(video: Bool) -> ResizeOption? {
        let options: [(String, ResizeOption)] = video
            ? [("1080p", .height(1080)), ("720p", .height(720)), ("480p", .height(480))]
            : [("25%", .scale(0.25)), ("50%", .scale(0.5)), ("75%", .scale(0.75)),
               ("Long edge 2560 px", .longEdge(2560)), ("Long edge 1920 px", .longEdge(1920)),
               ("Long edge 1280 px", .longEdge(1280))]
        let alert = NSAlert()
        alert.messageText = "Resize"
        alert.informativeText = "Choose a size. The original is kept."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26))
        popup.addItems(withTitles: options.map(\.0))
        popup.selectItem(at: video ? 0 : 1)
        alert.accessoryView = popup
        alert.addButton(withTitle: "Resize")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn ? options[popup.indexOfSelectedItem].1 : nil
    }
}
