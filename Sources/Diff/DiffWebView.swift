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
    private var pendingPayload: DiffPayload?

    var onError: ((String) -> Void)?

    /// Fires when the user finishes picking rows in the diff, and again with
    /// `nil` when they clear the pick.
    var onSelection: ((DiffRowRange?) -> Void)?

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

    func send(_ payload: DiffPayload) {
        guard isReady else {
            pendingPayload = payload
            return
        }
        evaluate(payload)
    }

    func setThemeType(_ theme: DiffPayload.ThemeType, canvas: String) {
        guard isReady else { return }
        let arguments: [String: Any] = ["theme": theme.rawValue, "canvas": canvas]
        webView.callAsyncJavaScript(
            "window.grove.setThemeType(theme, canvas)",
            arguments: arguments, in: nil, in: .page
        ) { [weak self] result in
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

    private func evaluate(_ payload: DiffPayload) {
        guard let json = payload.jsonString else {
            onError?("Could not encode the diff payload.")
            return
        }
        // Passed as an argument rather than interpolated into the script, so a
        // diff containing a quote, a backslash or `</script>` cannot break out
        // of it. A diff is untrusted input — it is the contents of a file.
        webView.callAsyncJavaScript(
            "window.grove.render(payload)",
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

/// What Swift hands the renderer. Mirrors `RenderPayload` in `Web/src/main.ts`.
struct DiffPayload: Encodable, Equatable {
    enum ThemeType: String, Encodable, Equatable {
        case light
        case dark
    }

    enum Style: String, Encodable, Equatable {
        case unified
        case split
    }

    var patch: String
    var fileName: String
    var diffStyle: Style
    var themeType: ThemeType
    var fontSize: Double
    /// The canvas colour, as `#rrggbb`, so the page matches the window rather
    /// than guessing at it.
    var canvas: String
    /// Cache key for the renderer's memoised output — it must change whenever
    /// the patch does, or a re-render shows the previous file.
    var generation: Int

    var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Bridges ``DiffWebSurface`` into SwiftUI.
struct DiffWebView: NSViewRepresentable {
    let payload: DiffPayload
    let onError: (String) -> Void
    var onSelection: (DiffRowRange?) -> Void = { _ in }
    /// Bumped by the owner to ask the page to drop its highlight. A counter
    /// rather than a flag, because two clears in a row are two events and a
    /// `Bool` would coalesce them into one.
    var clearSelectionToken: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let surface = DiffWebSurface()
        surface.onError = onError
        surface.onSelection = onSelection
        context.coordinator.surface = surface
        context.coordinator.clearedAt = clearSelectionToken
        context.coordinator.sent = payload
        surface.send(payload)
        return surface.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard let surface = context.coordinator.surface else { return }
        surface.onError = onError
        surface.onSelection = onSelection

        if context.coordinator.clearedAt != clearSelectionToken {
            context.coordinator.clearedAt = clearSelectionToken
            surface.clearSelection()
        }

        guard context.coordinator.sent != payload else { return }

        // A theme flip alone does not need the document rebuilt, and rebuilding
        // it would throw away the scroll position mid-appearance-change.
        if var previous = context.coordinator.sent,
            previous.themeType != payload.themeType
        {
            previous.themeType = payload.themeType
            previous.canvas = payload.canvas
            if previous == payload {
                context.coordinator.sent = payload
                surface.setThemeType(payload.themeType, canvas: payload.canvas)
                return
            }
        }

        context.coordinator.sent = payload
        surface.send(payload)
    }

    @MainActor
    final class Coordinator {
        var surface: DiffWebSurface?
        var sent: DiffPayload?
        var clearedAt = 0
    }
}
