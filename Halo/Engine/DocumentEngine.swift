import AppKit
import PDFKit

/// Text documents via NSAttributedString/PDFKit; Office files via LibreOffice when installed.
/// Main-actor bound because HTML import and print-to-PDF require the main thread.
@MainActor
enum DocumentEngine {
    static func convert(_ url: URL, to ext: String) async throws -> [URL] {
        let source = Catalog.normalize(url.pathExtension)
        let fm = FileManager.default

        // LibreOffice keeps Office layout intact; the native path is the fallback for DOCX.
        if ["ppt", "pptx", "docx"].contains(source), ["pdf", "jpg", "png"].contains(ext), Binaries.soffice != nil {
            let pdf = try await Office.run(url, filter: "pdf")
            defer { try? fm.removeItem(at: pdf.deletingLastPathComponent()) }
            if ext == "pdf" {
                let output = Output.url(for: url, ext: "pdf")
                try fm.moveItem(at: pdf, to: output)
                return [output]
            }
            return try await rasterize(pdf, source: url, ext: ext)
        }
        if source == "pdf", ["jpg", "png"].contains(ext) { return try await rasterize(url, source: url, ext: ext) }

        let text = try attributed(from: url)
        let output = Output.url(for: url, ext: ext)
        let range = NSRange(location: 0, length: text.length)
        switch ext {
        case "txt":
            try text.string.write(to: output, atomically: true, encoding: .utf8)
        case "md":
            try Markdown.from(text).write(to: output, atomically: true, encoding: .utf8)
        case "html":
            try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html]).write(to: output)
        case "docx":
            try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: output)
        case "pdf":
            try renderPDF(text, to: output)
        case "jpg", "png":
            let temp = try Output.tempDirectory()
            defer { try? fm.removeItem(at: temp) }
            let pdf = temp.appendingPathComponent("render.pdf")
            try renderPDF(text, to: pdf)
            return try await rasterize(pdf, source: url, ext: ext)
        default:
            throw HaloError("Can't convert \(source.uppercased()) to \(ext.uppercased())")
        }
        return [output]
    }

    static func attributed(from url: URL) throws -> NSAttributedString {
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black]
        switch Catalog.normalize(url.pathExtension) {
        case "pdf":
            guard let document = PDFDocument(url: url) else { throw HaloError("Can't open \(url.lastPathComponent)") }
            let result = NSMutableAttributedString()
            for i in 0..<document.pageCount {
                if let page = document.page(at: i)?.attributedString { result.append(page) }
                result.append(NSAttributedString(string: "\n\n"))
            }
            return result
        case "md":
            let html = Markdown.html(try String(contentsOf: url, encoding: .utf8))
            return try NSAttributedString(data: Data(html.utf8),
                                          options: [.documentType: NSAttributedString.DocumentType.html,
                                                    .characterEncoding: String.Encoding.utf8.rawValue],
                                          documentAttributes: nil)
        case "txt":
            return NSAttributedString(string: try String(contentsOf: url, encoding: .utf8), attributes: body)
        case "textclipping":
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
            let data = plist?["UTI-Data"] as? [String: Any]
            if let rtf = data?["public.rtf"] as? Data, let text = NSAttributedString(rtf: rtf, documentAttributes: nil) {
                return text
            }
            if let plain = data?["public.utf8-plain-text"] as? String { return NSAttributedString(string: plain, attributes: body) }
            throw HaloError("This clipping has no text")
        default:
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        }
    }

    static func renderPDF(_ text: NSAttributedString, to url: URL) throws {
        let page = NSSize(width: 595, height: 842), margin: CGFloat = 56
        let info = NSPrintInfo(dictionary: [.jobSavingURL: url])
        info.jobDisposition = .save
        info.paperSize = page
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.isHorizontallyCentered = false

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: page.width - 2 * margin, height: page.height))
        view.appearance = NSAppearance(named: .aqua)
        view.drawsBackground = false
        view.textStorage?.setAttributedString(text)
        if let layout = view.layoutManager, let container = view.textContainer {
            layout.ensureLayout(for: container)
            let height = layout.usedRect(for: container).height + 20
            view.setFrameSize(NSSize(width: view.frame.width, height: max(height, page.height - 2 * margin)))
        }

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw HaloError("Can't render PDF") }
    }

    /// One image per page; multi-page documents get "(page N)" suffixes.
    static func rasterize(_ pdf: URL, source: URL, ext: String) async throws -> [URL] {
        guard let document = PDFDocument(url: pdf) else { throw HaloError("Can't open \(pdf.lastPathComponent)") }
        var results: [URL] = []
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox), scale: CGFloat = 2
            guard let context = ImageEngine.makeContext(width: Int(bounds.width * scale), height: Int(bounds.height * scale)) else { continue }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)
            guard let image = context.makeImage() else { continue }
            let output = Output.url(for: source, ext: ext, suffix: document.pageCount > 1 ? "page \(i + 1)" : nil)
            try await ImageEngine.write(image, to: output, ext: ext)
            results.append(output)
        }
        return results
    }
}

enum Office {
    /// A private profile keeps headless runs from colliding with a LibreOffice window the user has open.
    private static let profile = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Halo/LibreOfficeProfile")

    /// Returns the produced file inside a fresh temp folder; callers move it and delete the folder.
    static func run(_ url: URL, filter: String, infilter: String? = nil) async throws -> URL {
        guard let soffice = Binaries.soffice else { throw HaloError("LibreOffice is required for this conversion") }
        let temp = try Output.tempDirectory()
        var args = ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--norestore",
                    "--convert-to", filter, "--outdir", temp.path]
        if let infilter { args.append("--infilter=\(infilter)") }
        args.append(url.path)
        try await Shell.run(soffice, args)
        guard let produced = try FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil).first else {
            throw HaloError("LibreOffice couldn't convert \(url.lastPathComponent)")
        }
        return produced
    }

    static func convertSheet(_ url: URL, to ext: String) async throws -> URL {
        let filter = switch ext {
        case "csv": "csv:Text - txt - csv (StarCalc):44,34,76"
        case "tsv": "csv:Text - txt - csv (StarCalc):9,34,76"
        default: ext
        }
        let isTSV = Catalog.normalize(url.pathExtension) == "tsv"
        let produced = try await run(url, filter: filter, infilter: isTSV ? "CSV:9,34,76" : nil)
        defer { try? FileManager.default.removeItem(at: produced.deletingLastPathComponent()) }
        let output = Output.url(for: url, ext: ext)
        try FileManager.default.moveItem(at: produced, to: output)
        return output
    }
}
