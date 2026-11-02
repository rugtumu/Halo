import AppKit
import QuickLookThumbnailing

@MainActor
enum Feedback {
    static func tick() {
        guard Prefs.haptic else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    static func success() {
        if Prefs.sound { NSSound(named: "Glass")?.play() }
    }

    static func failure() {
        if Prefs.sound { NSSound(named: "Basso")?.play() }
    }
}

enum Thumbnails {
    static func load(_ url: URL, size: CGFloat) async -> NSImage {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: 2, representationTypes: .all)
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return representation.nsImage
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
