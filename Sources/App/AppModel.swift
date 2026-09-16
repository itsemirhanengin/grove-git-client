import AppKit
import Foundation
import Observation

/// Long-lived collaborators, built once at launch.
struct AppServices {
    let environment: GitEnvironment
    let runner: GitRunner
    let limiter: GitTaskLimiter
}

@Observable
@MainActor
final class AppModel {

    var workspace: WorkspaceModel?
    var isBootstrapping = true
    var bootstrapError: String?

    private var services: AppServices?

    /// Resolves the git environment, then opens a workspace.
    ///
    /// Environment resolution asks a login shell for `PATH`, which costs a
    /// process, so it happens once here rather than per command.
    func bootstrap() async {
        let environment = await GitEnvironment.resolve()
        services = AppServices(
            environment: environment,
            runner: GitRunner(environment: environment),
            limiter: GitTaskLimiter()
        )
        isBootstrapping = false

        if let development = Self.developmentWorkspace {
            await open(development)
        }
    }

    func open(_ url: URL) async {
        guard let services else { return }

        let model = WorkspaceModel(
            root: url,
            runner: services.runner,
            limiter: services.limiter
        )
        workspace = model

        await model.discover()
    }

    func chooseWorkspace() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder containing your git repositories."
        panel.prompt = "Open Workspace"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        await open(url)
    }

    func refreshAll() async {
        await workspace?.refreshAll()
    }

    /// Until workspace persistence lands, a Debug build opens the generated
    /// `Fixtures/` workspace so there is always something real on screen.
    private static var developmentWorkspace: URL? {
        #if DEBUG
        guard let override = ProcessInfo.processInfo.environment["GROVE_WORKSPACE"] else {
            let fixtures = URL(filePath: #filePath)
                .deletingLastPathComponent()  // App
                .deletingLastPathComponent()  // Sources
                .deletingLastPathComponent()  // project root
                .appending(path: "Fixtures")
            return FileManager.default.fileExists(atPath: fixtures.path()) ? fixtures : nil
        }
        return URL(filePath: override)
        #else
        return nil
        #endif
    }
}
