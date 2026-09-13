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
        WindowGroup("LocalMCP") {
            ContentView(model: model)
                .frame(minWidth: 1000, minHeight: 700)
                .task {
                    model.startIfNeeded()
                }
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {
                Link("Datenschutzerklärung", destination: URL(string: "https://www.mobilebox-consulting.de/datenschutzerkl%C3%A4rung-privacy-policy/")!)
                Link("Support kontaktieren", destination: URL(string: "mailto:mobile_box@icloud.com")!)
            }
            CommandMenu("Server") {
                Button("Einrichtungsassistent öffnen") { model.showsSetup = true }
                Button("MCP-Token & Verbindung") { model.destination = .connection }
                Divider()
                Button("Datenschutzfreigaben verwalten") {
                    model.destination = .permissions
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("MCP-Token kopieren") {
                    model.copyCapabilityToken()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Divider()

                Button("Starten") {
                    model.startIfNeeded()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Neu starten") {
                    model.restart()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Stoppen") {
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
