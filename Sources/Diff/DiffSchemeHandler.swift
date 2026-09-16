import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the bundled diff renderer to the web view over `grove-diff://`.
///
/// Not `loadFileURL`, for one concrete reason: the renderer is code-split, and a
/// `file://` page has an **opaque origin**, so every dynamic `import()` fails
/// CORS. Inlining everything into one file would avoid that, but it means
/// parsing an 10 MB document — almost all of it syntax grammars for languages
/// the open file is not written in — every time the view is built.
///
/// A custom scheme gives the page a real origin and therefore working module
/// loading, while still reading only from the app bundle. There is no network:
/// anything outside the served directory is refused.
final class DiffSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "grove-diff"
    static let host = "renderer"

    /// The directory inside the bundle that is allowed to be served.
    private let root: URL

    /// `nil` when the renderer was not built into the bundle, which is a build
    /// configuration problem rather than something to crash on.
    static func bundledRoot(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "index", withExtension: "html", subdirectory: "DiffRenderer")?
            .deletingLastPathComponent()
    }

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// The URL of the renderer's entry point.
    static var indexURL: URL {
        URL(string: "\(scheme)://\(host)/index.html")!
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let resolved = resolve(url) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        do {
            let data = try Data(contentsOf: resolved)
            let response = URLResponse(
                url: url,
                mimeType: Self.mimeType(for: resolved),
                expectedContentLength: data.count,
                textEncodingName: "utf-8"
            )
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        } catch {
            task.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    /// Maps a request URL onto a file inside `root`, or `nil`.
    ///
    /// The containment check is what keeps a `../../` in a request from reading
    /// the rest of the bundle. The page is our own code, but a renderer that can
    /// be pointed at arbitrary files is not a thing worth shipping.
    private func resolve(_ url: URL) -> URL? {
        guard url.scheme == Self.scheme else { return nil }

        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }

        let candidate = root.appending(path: path.trimmingPrefix("/")).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") || candidate == root else { return nil }
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        // `text/javascript` and not `application/javascript`: WebKit refuses to
        // evaluate a module served with the wrong type, and fails silently.
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "html": return "text/html"
        case "json": return "application/json"
        case "wasm": return "application/wasm"
        case "svg": return "image/svg+xml"
        default:
            return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
        }
    }
}
