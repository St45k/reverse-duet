import AppKit
import SwiftUI

@main
struct ReverseDuetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppState.shared

    var body: some Scene {
        Window("Reverse Duet", id: "main") {
            RootView()
                .environmentObject(app)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 960, height: 660)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(app)
        } label: {
            Image(systemName: app.sessions.isEmpty ? "d.circle" : "d.circle.fill")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run` (no Info.plist).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keep serving from the menu bar
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppState.shared.openMainWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.prepareForTermination()
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !app.serverRunning {
            Text("Wireless (Duet Air) is off")
        } else if app.sessions.isEmpty {
            Text("No devices connected")
        } else {
            ForEach(app.sessions) { session in
                Text("\(session.name) — \(session.params.mode.label)")
            }
        }
        Text("Pairing code: \(app.pairingCode)")
        Divider()
        Button("Open Reverse Duet") {
            openWindow(id: "main")
            app.openMainWindow()
        }
        Button("Copy Connection Link") { app.copyLink() }
        if !app.sessions.isEmpty {
            Button("Disconnect All") { app.server.disconnectAll() }
        }
        Divider()
        Button("Quit Reverse Duet") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
