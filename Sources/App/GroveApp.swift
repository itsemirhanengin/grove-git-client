import SwiftUI

@main
struct GroveApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            // Shortcuts live in real menu commands rather than on buried buttons:
            // menu-backed shortcuts are discoverable, remappable in System
            // Settings, and fire regardless of which subview holds focus.
            CommandGroup(replacing: .newItem) {}
        }
    }
}
