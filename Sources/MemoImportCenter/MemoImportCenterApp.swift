import SwiftUI

@main
struct MemoImportCenterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ImportStore()

    var body: some Scene {
        WindowGroup("Memo Import Center", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.titleBar)

        MenuBarExtra("Memo Import Center", systemImage: "waveform") {
            MenuBarContent()
                .environmentObject(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var store: ImportStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Import Center") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Text("\(store.items.filter { $0.status == .readyForReview }.count) to review")
        Text("\(store.items.filter { $0.status == .needsAttention || $0.status == .failed }.count) need attention")
        Divider()
        Button("Quit") {
            NSApp.terminate(nil)
        }
    }
}
