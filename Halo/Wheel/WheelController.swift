import AppKit
import SwiftUI

/// Borderless panel that floats above everything without stealing focus from the drag source.
final class HUDPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }

    func center(at point: NSPoint) {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        var rect = NSRect(x: point.x - frame.width / 2, y: point.y - frame.height / 2,
                          width: frame.width, height: frame.height)
        if let visible = screen?.visibleFrame {
            rect.origin.x = min(max(rect.minX, visible.minX), visible.maxX - rect.width)
            rect.origin.y = min(max(rect.minY, visible.minY), visible.maxY - rect.height)
        }
        setFrame(rect, display: false)
    }
}

/// Receives the drag over the wheel and reports positions relative to the wheel center (y down).
private final class DropTargetView: NSView {
    var onHover: ((CGPoint?) -> Void)?
    var onDrop: ((CGPoint, [URL]) -> Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func local(_ info: NSDraggingInfo) -> CGPoint {
        let p = convert(info.draggingLocation, from: nil)
        return CGPoint(x: p.x - bounds.midX, y: bounds.midY - p.y)
    }

    /// Holding ⌘ turns a Finder drag into move-only; answering `.copy` then would make the drop bounce.
    /// Halo never moves the dragged file itself, so any offered operation is fine.
    private func operation(_ info: NSDraggingInfo) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        for op in [NSDragOperation.copy, .generic, .link, .move] where mask.contains(op) { return op }
        return .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onHover?(local(sender))
        return operation(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onHover?(local(sender))
        return operation(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onHover?(nil) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return onDrop?(local(sender), urls) ?? false
    }
}

@MainActor
final class WheelController {
    static let shared = WheelController()

    let model = WheelModel()
    private var urls: [URL] = []
    private var pendingHide: DispatchWorkItem?
    private lazy var panel: HUDPanel = makePanel()

    var currentKind: WheelKind? { panel.isVisible && model.visible ? model.kind : nil }

    private func makePanel() -> HUDPanel {
        let size = NSSize(width: WheelGeometry.size, height: WheelGeometry.size)
        let panel = HUDPanel(size: size)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let host = NSHostingView(rootView: WheelView(model: model))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        let drop = DropTargetView(frame: container.bounds)
        drop.autoresizingMask = [.width, .height]
        drop.onHover = { [weak self] point in self?.hover(point) }
        drop.onDrop = { [weak self] point, urls in self?.drop(at: point, urls: urls) ?? false }
        container.addSubview(host)
        container.addSubview(drop)
        panel.contentView = container
        return panel
    }

    func show(_ kind: WheelKind, urls: [URL]) {
        let items = WheelBuilder.items(kind, for: urls)
        guard !items.isEmpty else {
            Toast.show(.info, kind == .tools ? "No tools for this file yet" : "No conversions for this file")
            return
        }
        pendingHide?.cancel()
        self.urls = urls
        model.kind = kind
        model.items = items
        model.hovered = nil
        model.fired = nil
        model.style = Prefs.style
        model.caption = Self.caption(for: urls)
        loadThumbnail(for: urls.first)

        if !panel.isVisible {
            model.visible = false
            panel.center(at: NSEvent.mouseLocation)
            panel.orderFrontRegardless()
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.74)) { model.visible = true }
        Feedback.tick()
    }

    func hide() {
        guard panel.isVisible else { return }
        withAnimation(.easeOut(duration: 0.16)) { model.visible = false }
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    /// The drop callback may land just after mouse-up, so give it a moment before closing.
    func dragEnded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.hide() }
    }

    #if DEBUG
    func preview(_ kind: WheelKind) {
        show(kind, urls: [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/preview.png")])
        withAnimation { model.hovered = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.hide() }
    }
    #endif

    private func hover(_ point: CGPoint?) {
        let index = point.flatMap { WheelGeometry(count: model.items.count).index(at: $0) }
        guard index != model.hovered else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) { model.hovered = index }
        if index != nil { Feedback.tick() }
    }

    private func drop(at point: CGPoint, urls dropped: [URL]) -> Bool {
        guard let index = WheelGeometry(count: model.items.count).index(at: point) else {
            hide()
            return false
        }
        let item = model.items[index]
        let targets = dropped.isEmpty ? urls : dropped
        withAnimation(.easeOut(duration: 0.12)) { model.fired = index }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.hide()
            Executor.run(item.action, on: targets)
        }
        return true
    }

    private static func caption(for urls: [URL]) -> String {
        guard urls.count == 1, let url = urls.first else { return "\(urls.count) files" }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) : url.lastPathComponent
    }

    private func loadThumbnail(for url: URL?) {
        guard let url else { return model.thumbnail = nil }
        model.thumbnail = NSWorkspace.shared.icon(forFile: url.path)
        Task {
            let image = await Thumbnails.load(url, size: 120)
            if self.urls.first == url { self.model.thumbnail = image }
        }
    }
}
