import AppKit
import SwiftUI

@MainActor
final class ToastModel: ObservableObject {
    @Published var kind: Toast.Kind = .info
    @Published var text = ""
    @Published var visible = false
    var reveal: [URL] = []
}

/// Small status capsule near the bottom of the screen; click a finished result to reveal it.
@MainActor
enum Toast {
    enum Kind { case progress, success, failure, info }

    private static let model = ToastModel()
    private static var hideWork: DispatchWorkItem?
    private static let panel: HUDPanel = {
        let size = NSSize(width: 460, height: 64)
        let panel = HUDPanel(size: size)
        let host = NSHostingView(rootView: ToastView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        return panel
    }()

    static func show(_ kind: Kind, _ text: String, reveal: [URL] = []) {
        hideWork?.cancel()
        model.kind = kind
        model.text = text
        model.reveal = reveal
        panel.ignoresMouseEvents = reveal.isEmpty
        if !panel.isVisible {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 60))
            }
            panel.orderFrontRegardless()
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.visible = true }
        if kind != .progress {
            let work = DispatchWorkItem { hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (kind == .failure ? 4 : 2.6), execute: work)
        }
    }

    static func hide() {
        withAnimation(.easeOut(duration: 0.2)) { model.visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            if !model.visible { panel.orderOut(nil) }
        }
    }

    fileprivate static func revealResults() {
        guard !model.reveal.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(model.reveal)
        hide()
    }
}

private struct ToastView: View {
    @ObservedObject var model: ToastModel

    var body: some View {
        HStack(spacing: 10) {
            icon
            Text(model.text)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .haloSurface(Capsule(), glass: Prefs.style == .glass)
        .overlay(Capsule().strokeBorder(HaloPalette.spectrum, lineWidth: 1).opacity(0.5))
        .environment(\.colorScheme, .dark)
        .scaleEffect(model.visible ? 1 : 0.9)
        .opacity(model.visible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onTapGesture { Toast.revealResults() }
    }

    @ViewBuilder
    private var icon: some View {
        switch model.kind {
        case .progress: ProgressView().controlSize(.small)
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(HaloPalette.ice)
        case .failure: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .info: Image(systemName: "info.circle.fill").foregroundStyle(HaloPalette.indigo)
        }
    }
}
