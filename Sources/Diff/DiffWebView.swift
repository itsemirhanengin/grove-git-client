import SwiftUI
import WebKit

/// The diff surface: a `WKWebView` running the bundled renderer.
///
/// Built as a plain object rather than inside `makeNSView` so a test can
/// construct the real thing, drive it, and read pixels back. The previous
/// native renderer shipped twice showing nothing, because every test it had
/// checked the model and none of them checked that anything was drawn.
@MainActor
final class DiffWebSurface: NSObject {

    let webView: WKWebView

    /// Set once the page's module has run and installed `window.grove`.
    private(set) var isReady = false

    /// Held until the page is ready — `loadFileURL` and friends are
    /// asynchronous, and evaluating into a page whose script has not run yet
    /// silently does nothing.
    private var pendingPayload: DiffWebContent?

    var onError: ((String) -> Void)?

    /// Fires when the user finishes picking rows in the diff, and again with
    /// `nil` when they clear the pick.
    var onSelection: ((DiffRowRange?) -> Void)?

    /// Fires with the **whole** resolved file each time a conflict region is
    /// settled in the page.
    var onConflictResolved: ((String) -> Void)?

    /// Fires when a changeset finishes rendering, and again whenever a file in
    /// it is expanded or collapsed: the file list, and how many of them are
    /// currently closed.
    var onChangeset: (([ChangesetFile], Int) -> Void)?

    override init() {
        let configuration = WKWebViewConfiguration()
        if let root = DiffSchemeHandler.bundledRoot() {
            configuration.setURLSchemeHandler(
                DiffSchemeHandler(root: root), forURLScheme: DiffSchemeHandler.scheme)
        }
        // The renderer is a pure function of what Grove hands it. It has no
        // reason to keep cookies, caches or storage between launches.
        configuration.websiteDataStore = .nonPersistent()

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        // Through `webView.configuration`, not the local one: `WKWebView`
        // **copies** its configuration on init, so anything added to the
        // original afterwards is registered on an object the view never reads.
        webView.configuration.userContentController.add(
            MessageProxy(surface: self), name: "grove")

        // What WebKit paints before the page has, and behind it while it
        // scrolls past its own edges. Without it the view is white for the
        // fraction of a second the renderer takes to come up — which on a dark
        // window is a flash, and the first thing anyone notices.
        webView.underPageBackgroundColor = Palette.diffCanvas.nsColor
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        // Right-click → Inspect Element while building this out. Harmless in a
        // page that only ever renders our own diff.
        webView.isInspectable = true

        guard DiffSchemeHandler.bundledRoot() != nil else {
            onError?("The diff renderer is missing from the app bundle.")
            return
        }
        webView.load(URLRequest(url: DiffSchemeHandler.indexURL))
    }

    // MARK: Sending

    func send(_ content: DiffWebContent) {
        guard isReady else {
            pendingPayload = content
            return
        }
        evaluate(content)
    }

    func setAppearance(_ appearance: DiffAppearance) {
        guard isReady, let json = appearance.jsonString else { return }
        call("window.grove.setAppearance(payload)", ["payload": json])
    }

    /// Expand All / Collapse All, for the changeset.
    func setChangesetCollapsed(_ collapsed: Bool) {
        guard isReady else { return }
        call("window.grove.setChangesetCollapsed(collapsed)", ["collapsed": collapsed])
    }

    /// Jumps the changeset to one file. The page owns the scroll position —
    /// it is the only thing that knows where an unmounted file will land.
    func scrollToChangesetFile(_ id: String) {
        guard isReady else { return }
        call("window.grove.scrollToChangesetFile(id)", ["id": id])
    }

    private func call(_ script: String, _ arguments: [String: Any]) {
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) {
            [weak self] result in
            if case .failure(let error) = result {
                self?.onError?("\(error)")
            }
        }
    }

    /// Drops the highlight after the picked rows have been staged or discarded.
    func clearSelection() {
        guard isReady else { return }
        webView.callAsyncJavaScript(
            "window.grove.clearSelection()", arguments: [:], in: nil, in: .page
        ) { _ in }
    }

    private func evaluate(_ content: DiffWebContent) {
        guard let json = content.jsonString else {
            onError?("Could not encode the payload for the renderer.")
            return
        }
        // Passed as an argument rather than interpolated into the script, so a
        // file containing a quote, a backslash or `</script>` cannot break out
        // of it. Both payloads carry the contents of a file — untrusted input.
        webView.callAsyncJavaScript(
            content.bridgeCall,
            arguments: ["payload": json], in: nil, in: .page
        ) { [weak self] result in
            if case .failure(let error) = result {
                self?.onError?("\(error)")
            }
        }
    }

    // MARK: Receiving

    fileprivate func handle(_ body: Any) {
        guard let message = body as? [String: Any],
            let type = message["type"] as? String
        else { return }

        switch type {
        case "ready":
            isReady = true
            if let payload = pendingPayload {
                pendingPayload = nil
                evaluate(payload)
            }
        case "conflictResolved":
            if let contents = message["contents"] as? String { onConflictResolved?(contents) }
        case "changeset":
            let files = (message["files"] as? [[String: Any]] ?? []).compactMap(
                ChangesetFile.init(json:))
            onChangeset?(files, message["collapsedCount"] as? Int ?? 0)
        case "selection":
            let range = (message["range"] as? [String: Any]).flatMap(DiffRowRange.init(json:))
            onSelection?(range)
        case "error":
            onError?(message["message"] as? String ?? "The diff renderer failed.")
        default:
            break
        }
    }

    /// Breaks the retain cycle `WKUserContentController` would otherwise create
    /// by holding its message handler strongly, which keeps the whole web view
    /// alive for the life of the process.
    private final class MessageProxy: NSObject, WKScriptMessageHandler {
        weak var surface: DiffWebSurface?

        init(surface: DiffWebSurface) {
            self.surface = surface
        }

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            MainActor.assumeIsolated { surface?.handle(message.body) }
        }
    }
}

/// Grove's palette, resolved for one appearance and handed to the page.
///
/// The renderer lives in a `WKWebView`, which cannot see the window's
/// `NSAppearance` and so cannot resolve a dynamic colour — least of all the two
/// high-contrast variants, which have no CSS equivalent to fall back on. Swift
/// therefore resolves every colour the page needs and sends hex strings, and
/// nothing in the page is allowed to invent one. That is what keeps a diff from
/// drifting a shade away from the pane around it.
///
/// Mirrors `GroveChrome` in `Web/src/theme.ts`.
nonisolated struct DiffChrome: Encodable, Equatable, Sendable {
    var canvas: String
    var headerFill: String
    var border: String
    var rowSeparator: String
    var added: String
    var removed: String
    var modified: String
    var renamed: String
    var attention: String

    /// Main-actor because ``Palette`` is: the swatches are design-system state,
    /// and resolving one is something a view does while it is building a body.
    @MainActor static func resolved(for scheme: ColorScheme) -> DiffChrome {
        DiffChrome(
            canvas: Palette.diffCanvas.hexString(for: scheme),
            headerFill: Palette.headerFill.hexString(for: scheme),
            border: Palette.border.hexString(for: scheme),
            rowSeparator: Palette.rowSeparator.hexString(for: scheme),
            added: Palette.added.hexString(for: scheme),
            removed: Palette.removed.hexString(for: scheme),
            modified: Palette.modified.hexString(for: scheme),
            renamed: Palette.renamed.hexString(for: scheme),
            attention: Palette.attention.hexString(for: scheme)
        )
    }
}

/// How the page looks, as opposed to what it says.
///
/// Carried as its own value in every payload so a light/dark flip can be applied
/// on its own. Rebuilding the document instead would throw away the scroll
/// position at the exact moment the window is already changing under the reader.
///
/// Mirrors `GroveAppearance` in `Web/src/theme.ts`.
nonisolated struct DiffAppearance: Encodable, Equatable, Sendable {
    nonisolated enum ThemeType: String, Encodable, Equatable, Sendable {
        case light
        case dark
    }

    var themeType: ThemeType
    var fontSize: Double
    var chrome: DiffChrome

    @MainActor static func resolved(for scheme: ColorScheme) -> DiffAppearance {
        DiffAppearance(
            themeType: scheme == .dark ? .dark : .light,
            fontSize: Typography.diffSize,
            chrome: .resolved(for: scheme)
        )
    }

    var jsonString: String? { encodeToJSON(self) }
}

/// One file's diff. Mirrors `RenderPayload` in `Web/src/main.ts`.
nonisolated struct DiffPayload: Encodable, Equatable, Sendable {
    nonisolated enum Style: String, Encodable, Equatable, Sendable {
        case unified
        case split
    }

    var patch: String
    var fileName: String
    var diffStyle: Style
    /// Cache key for the renderer's memoised output — it must change whenever
    /// the patch does, or a re-render shows the previous file.
    var generation: Int
    var appearance: DiffAppearance

    var jsonString: String? { encodeToJSON(self) }
}

/// A whole commit, as one patch. Mirrors `ChangesetPayload` in
/// `Web/src/changeset.ts`.
nonisolated struct ChangesetPayload: Encodable, Equatable, Sendable {
    var patch: String
    /// The commit's id. It prefixes every item id in the page, so two commits
    /// can never be reconciled into each other — which is exactly what would
    /// happen if the first file of each were both identified as `0`.
    var key: String
    var diffStyle: DiffPayload.Style
    var generation: Int
    var appearance: DiffAppearance
}

/// A conflicted file, sent as the working-tree text with its markers intact.
///
/// Mirrors `ConflictPayload` in `Web/src/main.ts`.
nonisolated struct ConflictPayload: Encodable, Equatable, Sendable {
    var fileName: String
    var contents: String
    var generation: Int
    var appearance: DiffAppearance
}

/// One row of a changeset's file list, as the page reports it back.
///
/// Swift already knows which files a commit touched — it asked git. This is the
/// *rendered* list: the same files, with the ids the page will accept in a
/// scroll request and the counts it derived from the parse.
nonisolated struct ChangesetFile: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let prevName: String?
    let changeType: String
    let additions: Int
    let deletions: Int

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let name = json["name"] as? String else {
            return nil
        }
        self.id = id
        self.name = name
        prevName = json["prevName"] as? String
        changeType = json["changeType"] as? String ?? "change"
        additions = json["additions"] as? Int ?? 0
        deletions = json["deletions"] as? Int ?? 0
    }
}

private nonisolated func encodeToJSON(_ value: some Encodable) -> String? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return String(data: data, encoding: .utf8)
}

/// What the one web surface is currently showing.
///
/// Three payloads, one view. A file, a commit and a conflict are different
/// documents with different controls, but a second `WKWebView` would mean a
/// second renderer load and a second 650 kB parse for a pane that shows one of
/// them at a time.
enum DiffWebContent: Equatable {
    case diff(DiffPayload)
    case changeset(ChangesetPayload)
    case conflict(ConflictPayload)

    var bridgeCall: String {
        switch self {
        case .diff: "window.grove.render(payload)"
        case .changeset: "window.grove.renderChangeset(payload)"
        case .conflict: "window.grove.renderConflict(payload)"
        }
    }

    var jsonString: String? {
        switch self {
        case .diff(let payload): encodeToJSON(payload)
        case .changeset(let payload): encodeToJSON(payload)
        case .conflict(let payload): encodeToJSON(payload)
        }
    }

    /// The appearance half of the payload, which a theme flip can update on its
    /// own without rebuilding the document.
    var appearance: DiffAppearance {
        switch self {
        case .diff(let payload): payload.appearance
        case .changeset(let payload): payload.appearance
        case .conflict(let payload): payload.appearance
        }
    }

    /// The same content wearing another appearance, for deciding whether a
    /// change is *only* an appearance change.
    func withAppearance(of other: DiffWebContent) -> DiffWebContent {
        switch self {
        case .diff(var payload):
            payload.appearance = other.appearance
            return .diff(payload)
        case .changeset(var payload):
            payload.appearance = other.appearance
            return .changeset(payload)
        case .conflict(var payload):
            payload.appearance = other.appearance
            return .conflict(payload)
        }
    }
}

/// One thing to ask of a changeset that is already on screen.
///
/// Carried as a value with an identity rather than as a method, because a view
/// cannot call into its own `NSView`: it can only describe what it wants and let
/// `updateNSView` notice that the description changed. The `id` is what makes
/// two identical requests in a row two events rather than one.
struct ChangesetCommand: Equatable {
    enum Kind: Equatable {
        case setCollapsed(Bool)
        case scrollTo(String)
    }

    var id: Int
    var kind: Kind
}

/// Bridges ``DiffWebSurface`` into SwiftUI.
struct DiffWebView: NSViewRepresentable {
    let content: DiffWebContent
    let onError: (String) -> Void
    var onSelection: (DiffRowRange?) -> Void = { _ in }
    var onConflictResolved: (String) -> Void = { _ in }
    var onChangeset: ([ChangesetFile], Int) -> Void = { _, _ in }
    /// Bumped by the owner to ask the page to drop its highlight. A counter
    /// rather than a flag, because two clears in a row are two events and a
    /// `Bool` would coalesce them into one.
    var clearSelectionToken: Int = 0
    var command: ChangesetCommand?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let surface = DiffWebSurface()
        context.coordinator.surface = surface
        context.coordinator.clearedAt = clearSelectionToken
        context.coordinator.commandID = command?.id
        context.coordinator.sent = content
        attach(surface)
        surface.send(content)
        return surface.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard let surface = context.coordinator.surface else { return }
        attach(surface)

        if context.coordinator.clearedAt != clearSelectionToken {
            context.coordinator.clearedAt = clearSelectionToken
            surface.clearSelection()
        }

        if let command, context.coordinator.commandID != command.id {
            context.coordinator.commandID = command.id
            switch command.kind {
            case .setCollapsed(let collapsed): surface.setChangesetCollapsed(collapsed)
            case .scrollTo(let id): surface.scrollToChangesetFile(id)
            }
        }

        guard context.coordinator.sent != content else { return }

        // An appearance flip alone does not need the document rebuilt, and
        // rebuilding it would throw away the scroll position at the exact
        // moment the window is already changing under the reader.
        if let previous = context.coordinator.sent,
            previous.appearance != content.appearance,
            previous.withAppearance(of: content) == content
        {
            context.coordinator.sent = content
            surface.setAppearance(content.appearance)
            return
        }

        context.coordinator.sent = content
        surface.send(content)
    }

    /// The callbacks are re-bound on every update: each one captures whatever
    /// the enclosing view captured when this struct was built, and a surface
    /// still holding last update's closures reports into a stale view.
    private func attach(_ surface: DiffWebSurface) {
        surface.onError = onError
        surface.onSelection = onSelection
        surface.onConflictResolved = onConflictResolved
        surface.onChangeset = onChangeset
    }

    @MainActor
    final class Coordinator {
        var surface: DiffWebSurface?
        var sent: DiffWebContent?
        var clearedAt = 0
        var commandID: Int?
    }
}
