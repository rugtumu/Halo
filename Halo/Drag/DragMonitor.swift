import AppKit

/// Watches system-wide file drags and turns a quick modifier tap during the drag into a wheel.
///
/// Global mouse monitors need no Accessibility permission. Modifier state is polled from the
/// event source while a file drag is active, so idle cost is zero.
@MainActor
final class DragMonitor {
    private let pasteboard = NSPasteboard(name: .drag)
    private let relevantFlags: CGEventFlags = [.maskShift, .maskCommand, .maskControl, .maskAlternate]
    private let tapWindow: TimeInterval = 0.8
    private let holdDelay: TimeInterval = 0.25

    private var monitors: [Any] = []
    private var changeCountAtMouseDown = 0
    private var dragging = false
    private var urls: [URL] = []
    private var timer: Timer?
    private var heldSince: Date?
    private var peakFlags: CGEventFlags = []
    private var openedByHold = false
    /// Drag pasteboard generation already inspected, so non-file drags aren't re-read on every mouse move.
    private var inspectedChangeCount = -1

    func start() {
        addMonitor(.leftMouseDown) { [weak self] in
            guard let self else { return }
            changeCountAtMouseDown = pasteboard.changeCount
        }
        addMonitor(.leftMouseDragged) { [weak self] in self?.mouseDragged() }
        addMonitor(.leftMouseUp) { [weak self] in self?.dragEnded() }
    }

    private func addMonitor(_ mask: NSEvent.EventTypeMask, _ handler: @escaping () -> Void) {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in handler() }) {
            monitors.append(monitor)
        }
    }

    private func mouseDragged() {
        // A drag carries files only if the source wrote to the drag pasteboard after mouse down.
        let changeCount = pasteboard.changeCount
        guard !dragging, changeCount != changeCountAtMouseDown, changeCount != inspectedChangeCount else { return }
        inspectedChangeCount = changeCount
        let found = pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !found.isEmpty else { return }

        dragging = true
        urls = found
        heldSince = nil
        peakFlags = []
        openedByHold = false
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        // Mouse-up can be swallowed by the drop target, so check the button directly too.
        guard NSEvent.pressedMouseButtons & 1 == 1 else { return dragEnded() }

        let flags = CGEventSource.flagsState(.combinedSessionState).intersection(relevantFlags)
        if !flags.isEmpty {
            if heldSince == nil { heldSince = Date() }
            peakFlags.formUnion(flags)
            // Holding opens the wheel without waiting for release; a held wheel never toggles closed.
            if !openedByHold, let since = heldSince, Date().timeIntervalSince(since) >= holdDelay,
               let kind = Self.wheel(for: flags) {
                openedByHold = true
                if WheelController.shared.currentKind != kind { WheelController.shared.show(kind, urls: urls) }
            }
            return
        }
        guard let since = heldSince else { return }
        let combo = peakFlags, wasHeld = openedByHold
        heldSince = nil
        peakFlags = []
        openedByHold = false

        guard !wasHeld, Date().timeIntervalSince(since) < tapWindow, let kind = Self.wheel(for: combo) else { return }
        let wheel = WheelController.shared
        if wheel.currentKind == kind { wheel.hide() } else { wheel.show(kind, urls: urls) }
    }

    private static func wheel(for flags: CGEventFlags) -> WheelKind? {
        WheelKind.allCases.first { Prefs.modifier(for: $0).flag == flags }
    }

    private func dragEnded() {
        guard dragging else { return }
        dragging = false
        timer?.invalidate()
        timer = nil
        WheelController.shared.dragEnded()
    }
}
