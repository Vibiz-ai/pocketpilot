import OpenTapCore
import SwiftUI

/// Preview/test fixtures: an AppModel over the mock environment with no services started.
@MainActor
enum PreviewFixtures {
    static func model(step: OnboardingStep = .permissions, onboardingDone: Bool = false,
                      configure: (OpenTapEnvironment) -> Void = { _ in }) -> AppModel {
        let defaults = UserDefaults(suiteName: "dev.opentap.previews") ?? .standard
        defaults.set(onboardingDone, forKey: AppModel.onboardingDoneKey)
        let phone = MockPhone(elements: [
            .init(text: "Settings", center: CGPoint(x: 300, y: 400)),
            .init(text: "Safari", center: CGPoint(x: 880, y: 400)),
        ])
        let env = OpenTapEnvironment.mock(phone: phone, port: 0)
        configure(env)
        let model = AppModel(environment: env, defaults: defaults, autostart: false)
        model.currentStep = step
        return model
    }

    static let device = DeviceInfo(udid: "00008130-MOCK", name: "Mock iPhone", model: "iPhone",
                                   productType: "iPhone16,2", iosVersion: "18.1")

    /// Everything green except what the caller overrides.
    static func allGood(_ env: OpenTapEnvironment) {
        env.device.state.send(.attached(device, trust: .paired))
        env.frames.state.send(.running(deviceName: device.name))
        env.hid.state.send(.connected(hostName: device.name))
        env.mcp.state.send(.listening(host: MCPDefaults.host, port: MCPDefaults.port))
        env.status.set(.assistiveTouch, .ok("Pointer visible"))
        env.status.set(.calibration, .ok("Calibrated today"))
        env.log.info("mcp", "tools/call screenshot")
        env.log.info("control", "Tapped (120, 340); pointer landed within 2px")
    }
}

#Preview("1 Permissions") {
    let m = PreviewFixtures.model(step: .permissions)
    return OnboardingView().environmentObject(m).frame(width: 900, height: 620)
}

#Preview("2 USB: trust") {
    let m = PreviewFixtures.model(step: .usb) { env in
        env.device.state.send(.attached(PreviewFixtures.device, trust: .awaitingUserTrust))
    }
    return OnboardingView().environmentObject(m).frame(width: 900, height: 620)
}

#Preview("2 USB: unavailable") {
    let m = PreviewFixtures.model(step: .usb) { env in
        env.device.state.send(.unavailable(OpenTapError(.frameworkUnavailable,
            what: "Can't talk to iPhones over USB on this Mac",
            why: "MobileDevice.framework is missing",
            fix: "Unlock the iPhone and tap Trust when it asks")))
    }
    return OnboardingView().environmentObject(m).frame(width: 900, height: 620)
}

#Preview("3 Screen") {
    let m = PreviewFixtures.model(step: .screen) { env in
        env.frames.state.send(.waitingForDevice)
    }
    return OnboardingView().environmentObject(m).frame(width: 900, height: 620)
}

#Preview("4 Bluetooth") {
    let m = PreviewFixtures.model(step: .bluetooth) { env in
        env.hid.state.send(.advertising(name: "OpenTap"))
    }
    return OnboardingView().environmentObject(m).frame(width: 900, height: 620)
}

#Preview("5 AssistiveTouch") {
    let m = PreviewFixtures.model(step: .assistiveTouch) { env in
        env.hid.state.send(.connected(hostName: "Mock iPhone"))
    }
    return OnboardingView().environmentObject(m).frame(width: 900, height: 620)
}

#Preview("6 Calibration failed") {
    let m = PreviewFixtures.model(step: .calibration) { env in
        env.status.set(.calibration, .failed(OpenTapError(.pointerNotFound, what: "Calibration failed",
            why: "The pointer was not visible after parking in the top-left corner",
            fix: "Make sure AssistiveTouch is on and the iPhone is unlocked, then try again")))
    }
    return OnboardingView().environmentObject(m).frame(width: 900, height: 620)
}

#Preview("7 Agent") {
    let m = PreviewFixtures.model(step: .agent) { env in PreviewFixtures.allGood(env) }
    return OnboardingView().environmentObject(m).frame(width: 900, height: 620)
}

#Preview("Main window") {
    let m = PreviewFixtures.model(onboardingDone: true) { env in PreviewFixtures.allGood(env) }
    return RootView().environmentObject(m).frame(width: 900, height: 620)
}

#Preview("Error card") {
    ErrorCard(error: OpenTapError(.permissionDenied, what: "Camera access is turned off",
                                  why: "macOS delivers the iPhone screen as a camera-like device",
                                  fix: "Open System Settings > Privacy & Security > Camera and turn on OpenTap")) {}
        .padding().frame(width: 520)
}
