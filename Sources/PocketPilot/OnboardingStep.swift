import PocketPilotCore
import SwiftUI

/// The seven onboarding steps, in order.
enum OnboardingStep: Int, CaseIterable, Identifiable, Hashable {
    case permissions, usb, screen, bluetooth, assistiveTouch, calibration, agent

    var id: Int { rawValue }
    var number: Int { rawValue + 1 }

    var title: String {
        switch self {
        case .permissions: return "Permissions"
        case .usb: return "Plug in iPhone"
        case .screen: return "Screen"
        case .bluetooth: return "Bluetooth pairing"
        case .assistiveTouch: return "AssistiveTouch"
        case .calibration: return "Calibration"
        case .agent: return "Connect your agent"
        }
    }

    var headline: String {
        switch self {
        case .permissions: return "Let PocketPilot see and touch your iPhone"
        case .usb: return "Plug in your iPhone and tap Trust"
        case .screen: return "Your iPhone screen, live on this Mac"
        case .bluetooth: return "Pair this Mac as a Bluetooth keyboard and mouse"
        case .assistiveTouch: return "Turn on AssistiveTouch so the pointer shows"
        case .calibration: return "Measure how your iPhone moves the pointer"
        case .agent: return "Connect your AI agent"
        }
    }

    var symbol: String {
        switch self {
        case .permissions: return "lock.shield"
        case .usb: return "cable.connector"
        case .screen: return "iphone"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .assistiveTouch: return "circle.circle"
        case .calibration: return "scope"
        case .agent: return "sparkles"
        }
    }

    /// The status pill backing this step (permissions has none).
    var component: Component? {
        switch self {
        case .permissions: return nil
        case .usb: return .usb
        case .screen: return .screen
        case .bluetooth: return .bluetooth
        case .assistiveTouch: return .assistiveTouch
        case .calibration: return .calibration
        case .agent: return .mcp
        }
    }

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

/// Live state of a step, shown in the sidebar.
enum StepState: Equatable {
    case pending, working, needsYou, done, skipped, failed

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .working: return "Working"
        case .needsYou: return "Needs you"
        case .done: return "Done"
        case .skipped: return "Skipped"
        case .failed: return "Needs a fix"
        }
    }

    var symbol: String {
        switch self {
        case .pending: return "circle"
        case .working: return "circle.dotted"
        case .needsYou: return "hand.point.right.fill"
        case .done: return "checkmark.circle.fill"
        case .skipped: return "arrow.uturn.forward.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .pending: return .secondary
        case .working: return .blue
        case .needsYou: return .orange
        case .done: return .green
        case .skipped: return .secondary
        case .failed: return .red
        }
    }
}

/// Result of the "Test it" button on the agent step.
enum AgentTestState: Equatable {
    case idle, running, passed(String), failed(PocketPilotError)
}

/// Result of the one-click "Add to Claude Code" button.
enum ClaudeInstallState: Equatable {
    case idle, running, done(String), failed(PocketPilotError)
}
