import OpenTapCore
import SwiftUI

/// Sidebar of the 7 steps with live state + the current step's page.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.currentStep }, set: { if let s = $0 { model.select(s) } })) {
                Section("Set up OpenTap") {
                    ForEach(OnboardingStep.allCases) { step in
                        StepRow(step: step, state: model.state(of: step)).tag(step)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
            .safeAreaInset(edge: .bottom) {
                if model.onboardingDone {
                    Button("Close setup") { model.finishOnboarding() }
                        .buttonStyle(.link)
                        .padding(12)
                }
            }
        } detail: {
            StepPage(step: model.currentStep)
                .id(model.currentStep)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.2), value: model.currentStep)
    }
}

private struct StepRow: View {
    let step: OnboardingStep
    let state: StepState

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if state == .working {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: state.symbol).foregroundStyle(state.color)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(step.number). \(step.title)")
                Text(state.label).font(.caption).foregroundStyle(state == .pending ? .tertiary : .secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityLabel("Step \(step.number), \(step.title), \(state.label)")
    }
}

/// Common page chrome: icon, headline, body, error card, footer with primary action / skip / continue.
private struct StepPage: View {
    @EnvironmentObject var model: AppModel
    let step: OnboardingStep

    var body: some View {
        let state = model.state(of: step)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: step.symbol)
                            .font(.system(size: 26, weight: .regular))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 52, height: 52)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Step \(step.number) of \(OnboardingStep.allCases.count)")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text(step.headline).font(.title.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if state == .done {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(.green)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    StepContent(step: step)
                    if let error = model.error(for: step), state != .done {
                        ErrorCard(error: error, retry: retryAction)
                    }
                }
                .padding(32)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer(state: state).padding(.horizontal, 32).padding(.vertical, 14)
        }
        .animation(.spring(duration: 0.3), value: state)
    }

    @ViewBuilder private func footer(state: StepState) -> some View {
        HStack {
            if let prev = step.previous {
                Button { model.select(prev) } label: { Label("Back", systemImage: "chevron.left") }
            }
            Spacer()
            if model.canSkip(step), state != .done {
                Button("Skip for now") { model.skip(step) }
            }
            if step == .agent {
                Button("Finish") { model.finishOnboarding() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else if state == .done, let next = step.next {
                Button { model.select(next) } label: { Label("Continue", systemImage: "chevron.right") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var retryAction: (() -> Void)? {
        switch step {
        case .permissions: return { model.refreshPermissions() }
        case .usb: return { model.deviceLinkUnavailable ? model.restartDeviceLink() : model.requestTrust() }
        case .screen: return { model.restartCapture() }
        case .bluetooth: return { model.restartBluetooth() }
        case .assistiveTouch: return { model.enableAssistiveTouchOverUSB() }
        case .calibration: return { model.calibrate() }
        case .agent: return { model.stopMCP(); model.startMCP() }
        }
    }
}

private struct StepContent: View {
    @EnvironmentObject var model: AppModel
    let step: OnboardingStep

    var body: some View {
        switch step {
        case .permissions: PermissionsStep()
        case .usb: USBStep()
        case .screen: ScreenStep()
        case .bluetooth: BluetoothStep()
        case .assistiveTouch: AssistiveTouchStep()
        case .calibration: CalibrationStep()
        case .agent: AgentStep()
        }
    }
}
