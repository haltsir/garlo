import SwiftUI
import AppKit
import GarloCore

@main
struct GarloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore()

    init() {
        // Menu-bar-only app: no Dock icon even when run outside a bundle.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environment(store)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: store.iconState))
        }
        .menuBarExtraStyle(.window)

        Window("History", id: "history") {
            HistoryView().environment(store)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 960, height: 620)

        Window("Garlo Settings", id: "settings") {
            SettingsView().environment(store)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.shared.registerCategories()
    }
}
