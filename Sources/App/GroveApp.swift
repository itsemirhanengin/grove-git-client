import SwiftUI

@main
struct GroveApp: App {

    /// Owned here rather than by `RootView`, because the recovery window is a
    /// second scene over the same workspace — and a model that lives in one
    /// window's state cannot be reached from another.
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            // Shortcuts live in real menu commands rather than on buried buttons:
            // menu-backed shortcuts are discoverable, remappable in System
            // Settings, and fire regardless of which subview holds focus.
            CommandGroup(replacing: .newItem) {}
        }

        // A window, not a sheet. It is opened *because* something went wrong,
        // which is exactly when being unable to look at the repository
        // underneath would be worst.
        Window("Recovery", id: Self.recoveryWindowID) {
            RecoveryWindow(model: model)
        }
        .defaultSize(width: 860, height: 520)
        // The shortcut lives on the scene, which is also what puts "Recovery" in
        // the Window menu. Declaring it again on a command button would be two
        // views claiming one shortcut, which is undefined rather than redundant.
        .keyboardShortcut("r", modifiers: [.command, .shift])
    }

    static let recoveryWindowID = "recovery"
}
