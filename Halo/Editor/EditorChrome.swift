import AppKit
import SwiftUI

/// Hosts an editor in a borderless-looking, key-capable window with Halo's chrome.
@MainActor
enum EditorWindow {
    private static var windows: [NSWindow] = []

    static func present<V: View>(size: NSSize, content: (@escaping () -> Void) -> V) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 560)

        let close: () -> Void = { [weak window] in window?.close() }
        window.contentView = NSHostingView(rootView: content(close))
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { note in
            MainActor.assumeIsolated { windows.removeAll { $0 === note.object as? NSWindow } }
        }
        windows.append(window)
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

struct EditorChrome<Content: View, Controls: View>: View {
    let title: String
    var applyTitle = "Apply"
    var applyEnabled = true
    let close: () -> Void
    let apply: () -> Void
    @ViewBuilder let content: Content
    @ViewBuilder let controls: Controls

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title).font(.system(size: 16, weight: .bold, design: .rounded))
                HStack {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 26, height: 26)
                            .background(.white.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().opacity(0.4)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(14)

            controls
                .padding(.horizontal, 18)
                .padding(.bottom, 10)

            Divider().opacity(0.4)

            HStack {
                Spacer()
                Button(applyTitle, action: apply)
                    .buttonStyle(HaloButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!applyEnabled)
            }
            .padding(14)
        }
        .foregroundStyle(.white)
        .haloSurface(RoundedRectangle(cornerRadius: 26, style: .continuous), glass: Prefs.style == .glass)
        .environment(\.colorScheme, .dark)
    }
}

struct HaloButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(LinearGradient(colors: [HaloPalette.ice, HaloPalette.cobalt, HaloPalette.indigo],
                                       startPoint: .leading, endPoint: .trailing), in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// An aspect-fit image whose overlay receives the image's on-screen size,
/// so editors can work in normalized (0…1, top-left origin) coordinates.
struct FittedImage<Overlay: View>: View {
    let image: CGImage
    @ViewBuilder var overlay: (CGSize) -> Overlay

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .overlay { GeometryReader { overlay($0.size) } }
            .padding(14)
    }
}

extension FittedImage where Overlay == EmptyView {
    init(image: CGImage) {
        self.init(image: image) { _ in EmptyView() }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -1...1
    var format: (Double) -> String = { String(format: "%+d", Int(($0 * 100).rounded())) }
    var neutral = 0.0

    var body: some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Slider(value: $value, in: range).tint(HaloPalette.cobalt)
            Text(format(value)).monospacedDigit().frame(width: 64, alignment: .trailing)
            Button { value = neutral } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.plain)
                .opacity(value == neutral ? 0.3 : 0.9)
        }
        .font(.system(size: 12))
    }
}

/// Normalized point in an overlay of the given size, clamped to the image.
func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
    CGPoint(x: min(max(point.x / size.width, 0), 1), y: min(max(point.y / size.height, 0), 1))
}

func denormalized(_ rect: CGRect, in size: CGSize) -> CGRect {
    CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
           width: rect.width * size.width, height: rect.height * size.height)
}
