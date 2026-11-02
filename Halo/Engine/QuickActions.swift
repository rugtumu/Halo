import AppKit

@MainActor
enum QuickActions {
    static func perform(_ action: QuickAction, _ urls: [URL]) {
        switch action {
        case .airdrop:
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
                return Toast.show(.failure, "AirDrop is unavailable")
            }
            NSApp.activate()
            service.perform(withItems: urls)
        case .float:
            FloatShelf.add(urls)
        case .copy:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects(urls as [NSURL])
            Toast.show(.success, urls.count == 1 ? "Copied \(urls[0].lastPathComponent)" : "Copied \(urls.count) files")
        case .copyPath:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            Toast.show(.success, "Path copied")
        case .move:
            move(urls)
        case .terminal:
            openTerminal(at: urls[0])
        }
    }

    private static func move(_ urls: [URL]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        NSApp.activate()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let moved = try urls.map { url in
                let target = Output.unique(folder.appendingPathComponent(url.lastPathComponent))
                try FileManager.default.moveItem(at: url, to: target)
                return target
            }
            Feedback.success()
            Toast.show(.success, "Moved to \(folder.lastPathComponent)", reveal: moved)
        } catch {
            Feedback.failure()
            Toast.show(.failure, error.localizedDescription)
        }
    }

    private static func openTerminal(at url: URL) {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let folder = isDirectory ? url : url.deletingLastPathComponent()
        NSWorkspace.shared.open([folder], withApplicationAt: Prefs.terminalApp,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            DispatchQueue.main.async { Toast.show(.failure, error.localizedDescription) }
        }
    }
}
