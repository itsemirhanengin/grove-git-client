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

    /// Drives the spinning arrow in the bottom bar. A symbol effect rather than
    /// a `ProgressView`, because ten spinners in a sidebar is just noise.
    var isRefreshing = false

    private var services: AppServices?

    /// Live refresh. One stream for the whole workspace — see ``RepoWatcher``.
    private var watcher: RepoWatcher?

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

        // Stop before discovery, not after: the old workspace's repositories are
        // about to stop existing as far as this window is concerned, and a
        // refresh fired at one of them mid-swap has nothing to update.
        watcher?.stop()

        let model = WorkspaceModel(
            root: url,
            runner: services.runner,
            limiter: services.limiter
        )
        workspace = model

        await model.discover()
        startWatching()
    }

    /// Points the watcher at whatever discovery found.
    ///
    /// A repository refreshes itself when Grove changes it, so this exists for
    /// everything Grove did *not* do: a commit from the terminal, a branch
    /// switch in another tool, a build touching generated files.
    private func startWatching() {
        guard let workspace else { return }

        if watcher == nil {
            watcher = RepoWatcher { [weak self] changed in
                self?.repositoriesChangedOnDisk(changed)
            }
        }
        watcher?.watch(workspace.repos.map(\.repository))
    }

    private func repositoriesChangedOnDisk(_ changed: Set<RepoID>) {
        guard let workspace else { return }
        for repo in workspace.repos where changed.contains(repo.id) {
            // `refresh()` and not `refreshAndWait()`: these arrive unbidden and
            // must never hold anything up. It also cancels a refresh already in
            // flight, so a burst of events cannot pile up processes.
            repo.refresh()
        }
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
        isRefreshing = true
        defer { isRefreshing = false }
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
