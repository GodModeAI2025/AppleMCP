import AppKit
import SwiftUI

@main
struct M3MCPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup("M3MCP") {
            ContentView(model: model)
                .frame(minWidth: 960, minHeight: 640)
                .task {
                    model.startIfNeeded()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Server") {
                Button("Request Permissions") {
                    Task {
                        await model.requestPermissions()
                    }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("Copy MCP Client Token") {
                    model.copyCapabilityToken()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Divider()

                Button("Start") {
                    model.startIfNeeded()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Restart") {
                    model.restart()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Stop") {
                    model.stop()
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.log("applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.log("applicationWillTerminate")
    }
}
