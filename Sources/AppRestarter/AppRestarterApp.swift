import SwiftUI

@main
struct AppRestarterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("App Restarter", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 520)
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 420)
                .padding(20)
        }

        MenuBarExtra("App Restarter", systemImage: "arrow.triangle.2.circlepath") {
            StatusBarMenu()
                .environmentObject(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window.canBecomeMain else { return }
        let hasOtherVisibleWindows = NSApp.windows.contains {
            $0 !== window && $0.canBecomeMain && $0.isVisible
        }
        if !hasOtherVisibleWindows {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
