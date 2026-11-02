import SwiftUI

@main
struct HaloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(Prefs.Key.showMenuBar) private var showMenuBar = true

    var body: some Scene {
        MenuBarExtra("Halo", systemImage: "circle.circle", isInserted: $showMenuBar) {
            MenuContent()
        }
        Settings { SettingsView() }
    }
}

private struct MenuContent: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("Drag a file, then tap ⇧, ⌘ or ⌃")
        Divider()
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        #if DEBUG
        Menu("Preview Wheel") {
            ForEach(WheelKind.allCases) { kind in
                Button(kind.title) { WheelController.shared.preview(kind) }
            }
        }
        #endif
        Divider()
        Button("Quit Halo") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = DragMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        monitor.start()
        #if DEBUG
        // `open Halo.app --args -previewWheel tools` shows a wheel without a real drag.
        if let kind = UserDefaults.standard.string(forKey: "previewWheel").flatMap(WheelKind.init) {
            WheelController.shared.preview(kind)
        }
        #endif
    }

    // With the menu bar icon hidden, relaunching the app is the way back into Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        return true
    }
}
