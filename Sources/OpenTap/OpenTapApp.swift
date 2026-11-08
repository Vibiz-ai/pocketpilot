import OpenTapCore
import SwiftUI

/// Owner: frontend. Onboarding wizard + compact main window (preview, status pills, log).
@main
struct OpenTapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("OpenTap") {
            PlaceholderView(status: appDelegate.environment.status.snapshot.value)
                .frame(minWidth: 420, minHeight: 520)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment = OpenTapEnvironment.live()
}

struct PlaceholderView: View {
    let status: StatusSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OpenTap").font(.largeTitle.bold())
            ForEach(Component.allCases, id: \.self) { c in
                Text("\(c.title): \(status[c].detail)")
            }
        }
        .padding()
    }
}
