import SwiftUI

@main
struct AgenTTYMacOSApp: App {
    @State private var ghostty = GhosttyRuntime()

    var body: some Scene {
        WindowGroup {
            GhosttyTerminalViewMacOS(ghostty: ghostty)
                .frame(minWidth: 720, minHeight: 480)
        }
    }
}
