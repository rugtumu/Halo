import AppKit
import SwiftUI

/// The file being edited: a full-resolution image for export and a small one for live preview.
final class ImageDocument {
    let url: URL
    let ext: String
    let full: CGImage
    let preview: CGImage

    init(url: URL) throws {
        self.url = url
        ext = Catalog.normalize(url.pathExtension)
        full = try ImageEngine.load(url)
        let long = CGFloat(max(full.width, full.height))
        preview = long > 1400 ? ImageEngine.redraw(full, scale: 1400 / long) : full
    }

    /// Closes the editor and renders the full-resolution result off the main thread.
    @MainActor
    func save(_ suffix: String, close: () -> Void, render: @escaping (CGImage) -> CGImage?) {
        let full = full, url = url, ext = ext
        close()
        Executor.job("Saving…") {
            let image = try await Task.detached(priority: .userInitiated) {
                guard let image = render(full) else { throw HaloError("Couldn't render the image") }
                return image
            }.value
            let output = Output.url(for: url, ext: ext, suffix: suffix)
            try await ImageEngine.write(image, to: output, ext: ext, quality: 0.92)
            return [output]
        }
    }
}

@MainActor
enum Editors {
    static func handles(_ tool: Tool, _ url: URL) -> Bool {
        switch Catalog.row(for: url)?.category {
        case .image: tool.isImageEditor
        case .audio, .video: tool.isMediaEditor
        default: false
        }
    }

    static func open(_ tool: Tool, url: URL) {
        if tool.isMediaEditor { return MediaEditors.open(tool, url: url) }
        let document: ImageDocument
        do { document = try ImageDocument(url: url) } catch {
            return Toast.show(.failure, error.localizedDescription)
        }
        let size = NSSize(width: 780, height: 780)
        switch tool {
        case .edit: EditorWindow.present(size: size) { AdjustEditorView(doc: document, close: $0) }
        case .crop: EditorWindow.present(size: size) { CropEditorView(doc: document, close: $0) }
        case .redact: EditorWindow.present(size: size) { RedactEditorView(doc: document, close: $0) }
        case .annotate: EditorWindow.present(size: size) { AnnotateEditorView(doc: document, close: $0) }
        case .addBackground: EditorWindow.present(size: size) { BackgroundEditorView(doc: document, close: $0) }
        case .metadata: EditorWindow.present(size: NSSize(width: 620, height: 640)) { MetadataView(doc: document, close: $0) }
        case .compress, .resize, .trim, .channels, .bleep: break
        }
    }
}

/// Renders editor previews off the main thread. While a render runs, newer requests replace
/// each other, so dragging a slider renders at most one stale frame instead of a backlog.
@MainActor
final class PreviewRenderer: ObservableObject {
    @Published private(set) var image: CGImage?
    private var pending: (() -> CGImage?)?
    private var running = false
    private var generation = 0

    func update(_ work: @escaping () -> CGImage?) {
        pending = work
        if !running { drain() }
    }

    func clear() {
        generation += 1
        pending = nil
        image = nil
    }

    private func drain() {
        guard let work = pending else { running = false; return }
        pending = nil
        running = true
        let token = generation
        Task {
            let result = await Task.detached(priority: .userInitiated) { work() }.value
            if token == generation { image = result }
            drain()
        }
    }
}
