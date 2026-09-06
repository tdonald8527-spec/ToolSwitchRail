import SwiftUI

@main
struct ToolSwitchRailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
                .frame(width: 1, height: 1)
        }
    }
}
