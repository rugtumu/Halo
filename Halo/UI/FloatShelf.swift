import AppKit
import SwiftUI

@MainActor
final class ShelfModel: ObservableObject {
    @Published var urls: [URL]
    init(urls: [URL]) { self.urls = urls }

    func add(_ new: [URL]) {
        urls += new.filter { !urls.contains($0) }
    }
}

/// A floating tray that holds files so they can be dragged out again later.
@MainActor
enum FloatShelf {
    private static var panels: [(panel: HUDPanel, model: ShelfModel)] = []

    static func add(_ urls: [URL]) {
        if Prefs.floatBehaviour == .existing, let last = panels.last {
            last.model.add(urls)
            last.panel.orderFrontRegardless()
            return
        }
        let model = ShelfModel(urls: urls)
        let size = NSSize(width: 280, height: 170)
        let panel = HUDPanel(size: size)
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: ShelfView(model: model) { [weak panel] in
            guard let panel else { return }
            panel.orderOut(nil)
            panels.removeAll { $0.panel === panel }
        })
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.center(at: NSEvent.mouseLocation)
        panel.orderFrontRegardless()
        panels.append((panel, model))
    }
}

private struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.urls.count == 1 ? "1 file" : "\(model.urls.count) files")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.urls, id: \.self) { ShelfTile(url: $0) }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(width: 264, height: 154)
        .haloSurface(RoundedRectangle(cornerRadius: 22, style: .continuous), glass: Prefs.style == .glass)
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(HaloPalette.spectrum, lineWidth: 1).opacity(0.5))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ShelfTile: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: image ?? NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
            Text(url.lastPathComponent)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 76)
        }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .task { image = await Thumbnails.load(url, size: 64) }
    }
}
