import OpenTapCore
import SwiftUI

// MARK: 1. Permissions

struct PermissionsStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("OpenTap needs two macOS permissions. Nothing leaves this Mac.")
                .foregroundStyle(.secondary)
            PermissionRow(permission: .camera, title: "Camera",
                          why: "macOS delivers the iPhone screen over USB as a camera-like device.")
            PermissionRow(permission: .bluetooth, title: "Bluetooth",
                          why: "This Mac acts as a Bluetooth keyboard and mouse to tap and type on the iPhone.")
        }
    }
}

private struct PermissionRow: View {
    @EnvironmentObject var model: AppModel
    let permission: Permission
    let title: String
    let why: String

    var body: some View {
        let status = model.permissions[permission] ?? .notDetermined
        HStack(spacing: 14) {
            Image(systemName: permission == .camera ? "camera" : "dot.radiowaves.left.and.right")
                .font(.title2).frame(width: 30)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch status {
            case .granted:
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .notDetermined:
                Button("Allow \(title)") { model.request(permission) }.buttonStyle(.borderedProminent)
            case .denied, .restricted:
                Button("Open System Settings") { model.openSettings(permission) }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: 2. USB + Trust

struct USBStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.deviceState {
            case .unavailable:
                Text("OpenTap can't talk to the iPhone over USB on this Mac, so do this by hand:")
                InstructionList(items: [
                    "Plug the iPhone into this Mac with a USB cable.",
                    "Unlock the iPhone.",
                    "When it asks **Trust This Computer?**, tap **Trust** and enter your passcode.",
                ])
                screenHint
            case .idle, .noDevice:
                InstructionList(items: [
                    "Plug your iPhone into this Mac with a USB cable (use a data cable, not a charge-only one).",
                    "Unlock the iPhone.",
                    "Tap **Trust** when the iPhone asks, and enter your passcode.",
                ])
                LiveStatusLine(kind: .waiting, text: "Waiting for an iPhone on USB")
            case .attached(let d, let trust):
                deviceCard(d)
                switch trust {
                case .paired:
                    LiveStatusLine(kind: .ok, text: "\(d.name) trusts this Mac")
                case .locked:
                    HStack {
                        LiveStatusLine(kind: model.working.contains(.usb) ? .waiting : .warning,
                                       text: model.working.contains(.usb) ? "Unlock \(d.name); OpenTap checks again by itself" : "Unlock \(d.name) to continue")
                        Spacer()
                        Button("I've unlocked it, check again") { model.requestTrust() }
                            .disabled(model.working.contains(.usb))
                    }
                case .awaitingUserTrust:
                    LiveStatusLine(kind: .waiting, text: "On \(d.name), tap Trust and enter your passcode")
                case .denied:
                    LiveStatusLine(kind: .warning, text: "\"Don't Trust\" was tapped. Unplug and replug the iPhone to be asked again (the card below says what to do if no alert appears)")
                case .notPaired, .unknown:
                    HStack {
                        LiveStatusLine(kind: .waiting, text: "Not trusted yet")
                        Spacer()
                        Button("Ask iPhone to trust this Mac") { model.requestTrust() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.working.contains(.usb))
                    }
                }
            }
        }
    }

    private var screenHint: some View {
        Group {
            if case .running(let name) = model.frameState {
                LiveStatusLine(kind: .ok, text: "Screen from \(name) is coming through, so USB is working")
            } else {
                LiveStatusLine(kind: .waiting, text: "Waiting for the iPhone screen to appear over USB")
            }
        }
    }

    private func deviceCard(_ d: DeviceInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone").font(.system(size: 28)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.name).font(.headline)
                Text("\(d.productType) · iOS \(d.iosVersion)").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: 3. Screen

struct ScreenStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            PhonePreview(image: model.preview, frameSize: model.frameSize, placeholder: placeholder)
                .frame(width: 200, height: 420)
            VStack(alignment: .leading, spacing: 14) {
                Text("This is what your agent will see. Keep the iPhone unlocked and plugged in.")
                    .fixedSize(horizontal: false, vertical: true)
                switch model.frameState {
                case .running(let name):
                    LiveStatusLine(kind: .ok, text: "Live from \(name)")
                case .starting:
                    LiveStatusLine(kind: .waiting, text: "Starting screen capture")
                case .waitingForDevice, .idle:
                    LiveStatusLine(kind: .waiting, text: "Waiting for the iPhone screen (it can take a few seconds after plugging in)")
                case .failed:
                    LiveStatusLine(kind: .warning, text: "Screen capture stopped")
                }
                if model.permissions[.camera] != .granted {
                    LiveStatusLine(kind: .warning, text: "Camera access is needed first (step 1)")
                }
                Button("Restart screen capture") { model.restartCapture() }
            }
        }
    }

    private var placeholder: String {
        if case .failed = model.frameState { return "No screen" }
        return "Waiting for the iPhone screen"
    }
}

// MARK: 4. Bluetooth

struct BluetoothStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your agent taps and types through Bluetooth: this Mac shows up on the iPhone as a keyboard and mouse.")
                .fixedSize(horizontal: false, vertical: true)
            InstructionList(items: [
                "On the iPhone, open **Settings > Bluetooth** and make sure Bluetooth is on.",
                "Under **Other Devices**, tap **\(advertisedName)**.",
                "If the iPhone asks to pair, tap **Pair**. If this Mac also shows a pairing request, accept it.",
            ])
            ForEach(Array(model.pairingWarnings.enumerated()), id: \.offset) { _, w in
                ErrorCard(error: w, retryTitle: "Restart Bluetooth") { model.restartBluetooth() }
            }
            if model.bluetoothHostMismatch != nil {
                Button("It's the same iPhone") { model.acceptBluetoothHost() }
            }
            HStack {
                statusLine
                Spacer()
                switch model.hidState {
                case .off, .failed, .unavailable:
                    Button("Make this Mac discoverable") { model.startBluetooth() }
                        .buttonStyle(.borderedProminent)
                default:
                    Button("Restart Bluetooth") { model.restartBluetooth() }
                }
            }
            Text("Keep this window open while pairing. If \(advertisedName) doesn't appear, turn Bluetooth off and on on the iPhone.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var advertisedName: String {
        if case .advertising(let n) = model.hidState { return n }
        return "OpenTap"
    }

    @ViewBuilder private var statusLine: some View {
        switch model.hidState {
        case .off: LiveStatusLine(kind: .warning, text: "Bluetooth keyboard is off")
        case .unavailable: LiveStatusLine(kind: .warning, text: "Bluetooth isn't available")
        case .advertising(let n):
            LiveStatusLine(kind: .waiting, text: model.pairingWarnings.isEmpty
                           ? "Discoverable as \"\(n)\". Waiting for the iPhone"
                           : "Advertising as \"\(n)\" with problems (see below). Waiting for the iPhone")
        case .connecting: LiveStatusLine(kind: .waiting, text: "iPhone is connecting")
        case .connected(let host):
            if model.bluetoothHostMismatch != nil {
                LiveStatusLine(kind: .warning, text: "Connected to \(host ?? "another device"), not the iPhone on the cable")
            } else {
                LiveStatusLine(kind: .ok, text: host.map { "Connected to \($0)" } ?? "Connected")
            }
        case .failed: LiveStatusLine(kind: .warning, text: "Bluetooth stopped")
        }
    }
}

// MARK: 5. AssistiveTouch

struct AssistiveTouchStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            PhonePreview(image: model.preview, frameSize: model.frameSize)
                .frame(width: 180, height: 380)
            VStack(alignment: .leading, spacing: 14) {
                Text("iOS only shows a mouse pointer when AssistiveTouch is on. OpenTap needs to see it to aim taps.")
                    .fixedSize(horizontal: false, vertical: true)
                if model.isVerified(.assistiveTouch) {
                    LiveStatusLine(kind: .ok, text: "Pointer found on the iPhone screen")
                } else {
                    switch model.assistiveTouchAutoEnabled {
                    case .some(true):
                        if model.usbAssistiveTouchDidNotTakeEffect {
                            LiveStatusLine(kind: .warning, text: "The USB switch didn't take effect. Turn it on by hand:")
                        } else {
                            LiveStatusLine(kind: .waiting, text: "Asked the iPhone to turn on AssistiveTouch over USB; checking for the pointer")
                        }
                    case .some(false):
                        LiveStatusLine(kind: .warning, text: "Couldn't turn it on over USB. Do it on the iPhone:")
                    case .none:
                        if model.working.contains(.assistiveTouch) {
                            LiveStatusLine(kind: .waiting, text: "Turning on AssistiveTouch over USB")
                        }
                    }
                    InstructionList(items: [
                        "On the iPhone open **Settings > Accessibility > Touch > AssistiveTouch**.",
                        "Turn **AssistiveTouch** on.",
                        "A small round pointer appears when the mouse moves. OpenTap wiggles it to find it.",
                    ])
                    LiveStatusLine(kind: .waiting, text: "Looking for the pointer")
                    HStack {
                        Button("Turn on over USB") { model.enableAssistiveTouchOverUSB() }
                            .disabled(model.deviceState.device == nil || model.working.contains(.assistiveTouch))
                        Button("Look again") { model.startPointerProbe() }
                    }
                }
            }
        }
    }
}

// MARK: 6. Calibration

struct CalibrationStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("iOS speeds up the pointer the faster it moves. OpenTap measures that curve once so taps land exactly where your agent aims.")
                .fixedSize(horizontal: false, vertical: true)
            InstructionList(items: [
                CalibrationPlan.plainScreenAdvice + ".",
                "Don't touch the iPhone or the Mac's mouse for about 30 seconds.",
                "Press **Start calibration**.",
            ])
            if let p = model.calibrationProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: min(max(p.fraction, 0), 1))
                    Text(p.message).font(.callout).foregroundStyle(.secondary)
                }
            } else if model.isVerified(.calibration) {
                LiveStatusLine(kind: .ok, text: model.status[.calibration].detail)
            }
            HStack {
                if !model.status.canControl && !model.isVerified(.bluetooth) {
                    LiveStatusLine(kind: .warning, text: "Needs Bluetooth (step 4) and AssistiveTouch (step 5)")
                }
                Spacer()
                Button(model.isVerified(.calibration) ? "Calibrate again" : "Start calibration") { model.calibrate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isCalibrating)
            }
        }
    }
}

// MARK: 7. Agent

struct AgentStep: View {
    @EnvironmentObject var model: AppModel

    @ViewBuilder private var registrationLine: some View {
        switch model.claudeRegistration {
        case .none: EmptyView()
        case .added(let url): LiveStatusLine(kind: .ok, text: "Claude Code has opentap at \(url)")
        case .notAdded: LiveStatusLine(kind: .warning, text: "Not added to Claude Code yet: press Add to Claude Code or run the command")
        case .otherURL(let url): LiveStatusLine(kind: .warning, text: "Claude Code's opentap points at \(url); press Add to Claude Code to replace it")
        case .notInstalled: LiveStatusLine(kind: .warning, text: "Claude Code wasn't found on this Mac (use the command where it is installed)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                switch model.mcpState {
                case .listening(let h, let p): LiveStatusLine(kind: .ok, text: "MCP server running at http://\(h):\(p)\(MCPDefaults.path)")
                case .starting: LiveStatusLine(kind: .waiting, text: "Starting the MCP server")
                case .stopped: LiveStatusLine(kind: .warning, text: "MCP server is stopped")
                case .failed: LiveStatusLine(kind: .warning, text: "MCP server failed to start")
                }
                Spacer()
                if !model.mcpRunning { Button("Start server") { model.startMCP() } }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Claude Code").font(.headline)
                CopyField(text: MCPDefaults.claudeAddCommand) { model.copyMCPCommand() }
                HStack(spacing: 10) {
                    Button { model.addToClaudeCode() } label: {
                        Label("Add to Claude Code", systemImage: "plus.circle")
                    }
                    .disabled(model.claudeInstall == .running)
                    switch model.claudeInstall {
                    case .idle: EmptyView()
                    case .running: ProgressView().controlSize(.small)
                    case .done(let msg): LiveStatusLine(kind: .ok, text: msg)
                    case .failed: EmptyView()
                    }
                }
                if case .failed(let e) = model.claudeInstall {
                    ErrorCard(error: e, retryTitle: "Try again") { model.addToClaudeCode() }
                }
                registrationLine
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Any other MCP client").font(.headline)
                Text("Add a Streamable HTTP server with this URL:").font(.callout).foregroundStyle(.secondary)
                CopyField(text: MCPDefaults.url)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button { model.testAgentConnection() } label: { Label("Test it", systemImage: "checkmark.seal") }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.agentTest == .running)
                    switch model.agentTest {
                    case .idle: Text("Calls the status tool over MCP, just like your agent will.").font(.callout).foregroundStyle(.secondary)
                    case .running: ProgressView().controlSize(.small)
                    case .passed: LiveStatusLine(kind: .ok, text: "The OpenTap server answers like it will for your agent")
                    case .failed: EmptyView()
                    }
                }
                if case .passed(let text) = model.agentTest {
                    Text(text).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(6).textSelection(.enabled)
                }
                if case .failed(let e) = model.agentTest {
                    ErrorCard(error: e, retryTitle: "Test again") { model.testAgentConnection() }
                }
            }
            if !model.unfinishedSteps.isEmpty {
                Text("Still to do: \(model.unfinishedSteps.map(\.title).joined(separator: ", ")). You can finish now and come back with **OpenTap > Run Setup Again**.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Try asking your agent: \"Take a screenshot of my iPhone and open Settings.\"")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
