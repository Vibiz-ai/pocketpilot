import AppKit
import OpenTapCore
import SwiftUI

/// Owner: frontend. Onboarding wizard + compact main window (preview, status pills, log) + menu bar extra.
@main
struct OpenTapApp: App {
    static let mainWindowID = "main"
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("OpenTap", id: Self.mainWindowID) {
            RootView().environmentObject(appDelegate.model)
        }
        .defaultSize(width: 900, height: 620)
        .commands { AppCommands(model: appDelegate.model) }

        MenuBarExtra {
            MenuBarView().environmentObject(appDelegate.model)
        } label: {
            MenuBarIcon(model: appDelegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel.live()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
}

private struct MenuBarIcon: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Image(systemName: model.status.canControl ? "hand.tap.fill" : "hand.tap")
    }
}

private struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Run Setup Again…") { model.beginOnboarding() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandMenu("Phone") {
            Button("Recalibrate") { model.calibrate() }.disabled(model.isCalibrating)
            Button("Copy MCP Command") { model.copyMCPCommand() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Divider()
            Button(model.mcpRunning ? "Stop MCP Server" : "Start MCP Server") {
                model.mcpRunning ? model.stopMCP() : model.startMCP()
            }
            Button("Restart Bluetooth") { model.restartBluetooth() }
            Button("Restart Screen Capture") { model.restartCapture() }
            Divider()
            Button("Press Home") { model.pressHome() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!model.hidState.isConnected)
        }
    }
}
