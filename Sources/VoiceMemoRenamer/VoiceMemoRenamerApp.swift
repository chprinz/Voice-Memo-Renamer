import SwiftUI

@main
struct VoiceMemoRenamerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ImportStore()

    var body: some Scene {
        WindowGroup("Voice Memo Renamer", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 940, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1040, height: 720)

        MenuBarExtra("Voice Memo Renamer", systemImage: "waveform") {
            MenuBarContent()
                .environmentObject(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        updateApplicationIcon()
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateApplicationIcon()
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(appearanceObserver)
        }
    }

    private func updateApplicationIcon() {
        let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let iconName = isDarkMode ? "AppIconDark" : "AppIcon"
        guard let iconURL = Bundle.main.url(forResource: iconName, withExtension: "icns")
            ?? Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL) else {
            return
        }
        NSApp.applicationIconImage = icon
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var store: ImportStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Voice Memo Renamer") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Text("\(store.items.filter { $0.status == .readyForReview || $0.status == .needsAttention || $0.status == .failed }.count) need action")
        Divider()
        Button("Quit") {
            NSApp.terminate(nil)
        }
    }
}
