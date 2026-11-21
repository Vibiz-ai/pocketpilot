import PocketPilotCore
import SwiftUI

/// Compact window after onboarding: live preview, status pills, recent actions log, controls.
struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var showDebug = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 10) {
                PhonePreview(image: model.preview, frameSize: model.frameSize,
                             lastTap: model.lastTap, lastTapAt: model.lastTapAt,
                             placeholder: previewPlaceholder,
                             onTap: model.clickToTap ? { model.tap(atFramePoint: $0) } : nil)
                    .frame(minWidth: 200, idealWidth: 260, minHeight: 420)
                Toggle("Click to tap", isOn: $model.clickToTap)
                    .toggleStyle(.switch).controlSize(.small)
                    .disabled(!model.status.canControl)
                    .help("Clicks on the preview tap the iPhone at that spot")
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                header
                StatusPillRow(snapshot: model.status)
                if let problem = firstProblem {
                    ErrorCard(error: problem.1, retryTitle: "Fix in setup") {
                        model.beginOnboarding()
                        if let step = OnboardingStep.allCases.first(where: { $0.component == problem.0 }) { model.select(step) }
                    }
                }
                controls
                HStack {
                    Text("Recent activity").font(.headline)
                    Spacer()
                    Toggle("Debug", isOn: $showDebug).toggleStyle(.checkbox).controlSize(.small)
                }
                LogView(entries: model.logEntries, minimumLevel: showDebug ? .debug : .info)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(minHeight: 160)
            }
            .padding(20)
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.status.device?.name ?? "No iPhone").font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.status.canControl {
                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Finish setup") { model.beginOnboarding() }
            }
        }
    }

    private var subtitle: String {
        if let d = model.status.device { return "\(d.productType) · iOS \(d.iosVersion)" }
        return "Plug in your iPhone with a USB cable"
    }

    private var previewPlaceholder: String {
        switch model.frameState {
        case .failed(let e): return e.what
        case .running: return "Waiting for the first frame"
        default: return "Waiting for the iPhone screen"
        }
    }

    private var firstProblem: (Component, PocketPilotError)? {
        for c in Component.allCases { if let e = model.status[c].error { return (c, e) } }
        return nil
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button { model.copyMCPCommand() } label: { Label("Copy MCP command", systemImage: "doc.on.doc") }
                .help(MCPDefaults.claudeAddCommand)
            if model.mcpRunning {
                Button { model.stopMCP() } label: { Label("Stop server", systemImage: "stop.circle") }
            } else {
                Button { model.startMCP() } label: { Label("Start server", systemImage: "play.circle") }
            }
            Button { model.calibrate() } label: {
                if model.isCalibrating {
                    HStack(spacing: 6) {
                        ProgressView(value: model.calibrationProgress?.fraction ?? 0).frame(width: 50)
                        Text("Calibrating")
                    }
                } else {
                    Label("Recalibrate", systemImage: "scope")
                }
            }
            .disabled(model.isCalibrating)
            Button { model.pressHome() } label: { Label("Home", systemImage: "house") }
                .disabled(!model.hidState.isConnected)
        }
        .controlSize(.regular)
    }
}

/// Menu bar extra: one-glance status and the main actions.
struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.status.canControl ? "PocketPilot is ready" : "PocketPilot needs setup")
        Divider()
        ForEach(Component.allCases, id: \.self) { c in
            let s = model.status[c]
            Label("\(c.title): \(s.detail)", systemImage: s.health.symbol)
        }
        Divider()
        Button("Open PocketPilot") { openMain() }
        Button("Run Setup Again…") { model.beginOnboarding(); openMain() }
        Button("Copy MCP command") { model.copyMCPCommand() }
        Button(model.mcpRunning ? "Stop MCP server" : "Start MCP server") {
            model.mcpRunning ? model.stopMCP() : model.startMCP()
        }
        Button("Recalibrate") { model.calibrate() }.disabled(model.isCalibrating)
        Divider()
        Button("Quit PocketPilot") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func openMain() {
        openWindow(id: PocketPilotApp.mainWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Main window root: onboarding until done (or when re-run), then the compact main view.
struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.showOnboarding {
                OnboardingView().frame(minWidth: 820, minHeight: 580)
            } else {
                MainView().frame(minWidth: 700, minHeight: 540)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.showOnboarding)
    }
}
