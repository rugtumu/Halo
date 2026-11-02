import AppKit

enum Converter {
    /// Hides targets whose engine is missing, so the wheel never offers something that will fail.
    static func isAvailable(_ category: FileCategory, from source: String, to target: String) -> Bool {
        switch category {
        case .audio, .video: Binaries.ffmpeg != nil
        case .image: ImageEngine.canWrite(target)
        case .spreadsheet: Binaries.soffice != nil
        case .document: !["ppt", "pptx"].contains(source) || Binaries.soffice != nil
        case .archive, .subtitle: true
        }
    }

    /// Batches run a few files at once (ffmpeg and ImageIO are single-file bound), keeping result order.
    static func convertAll(_ urls: [URL], to ext: String, maxConcurrent: Int = 3) async throws -> [URL] {
        try await withThrowingTaskGroup(of: (Int, [URL]).self) { group in
            var results = [[URL]](repeating: [], count: urls.count)
            var next = 0
            func enqueue() {
                guard next < urls.count else { return }
                let index = next, url = urls[index]
                next += 1
                group.addTask { (index, try await convert(url, to: ext)) }
            }
            for _ in 0..<min(maxConcurrent, urls.count) { enqueue() }
            while let (index, outputs) = try await group.next() {
                results[index] = outputs
                enqueue()
            }
            return results.flatMap { $0 }
        }
    }

    static func convert(_ url: URL, to ext: String) async throws -> [URL] {
        guard let row = Catalog.row(for: url) else { throw HaloError("Unsupported file: \(url.lastPathComponent)") }
        switch row.category {
        case .image: return [try await ImageEngine.convert(url, to: ext)]
        case .document: return try await DocumentEngine.convert(url, to: ext)
        case .spreadsheet: return [try await Office.convertSheet(url, to: ext)]
        case .audio, .video: return [try await MediaEngine.convert(url, to: ext)]
        case .archive: return [try await ArchiveEngine.convert(url, to: ext)]
        case .subtitle: return [try SubtitleEngine.convert(url, to: ext)]
        }
    }
}

@MainActor
enum Executor {
    static func run(_ action: WheelAction, on urls: [URL]) {
        switch action {
        case .quick(let action):
            QuickActions.perform(action, urls)
        case .convert(let ext):
            job("Converting to \(ext.uppercased())…") { try await Converter.convertAll(urls, to: ext) }
        case .tool(let tool):
            if let url = urls.first, Editors.handles(tool, url) { return Editors.open(tool, url: url) }
            job("\(tool.progressTitle)…") { try await ToolEngine.run(tool, on: urls) }
        }
    }

    static func job(_ title: String, _ work: @escaping @MainActor () async throws -> [URL]) {
        Toast.show(.progress, title)
        Task { @MainActor in
            do {
                let results = try await work()
                guard !results.isEmpty else { return Toast.hide() }
                Feedback.success()
                let text = results.count == 1 ? results[0].lastPathComponent : "\(results.count) files saved"
                Toast.show(.success, text, reveal: results)
                if Prefs.reveal { NSWorkspace.shared.activateFileViewerSelecting(results) }
            } catch {
                Feedback.failure()
                Toast.show(.failure, error.localizedDescription)
            }
        }
    }
}
