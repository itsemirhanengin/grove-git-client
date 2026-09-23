import AppKit
import Testing
import WebKit

@testable import Grove

/// Does the diff surface actually put ink on the screen?
///
/// The native renderer that preceded this one shipped twice showing nothing,
/// while every test it had passed — because all of them checked the model and
/// none of them checked that anything was drawn. These tests mount the real
/// surface in a real window, drive it the way the app does, and read the pixels
/// back.
///
/// **All but the first are currently disabled.** They pass nothing and fail
/// nothing: `WKWebView` never finishes loading inside the xcodebuild test host,
/// which logs `RBS assertion … com.apple.runningboard.assertions.webkit` and
/// never brings up a WebContent process. The same code renders correctly in the
/// running app. Re-enable them the moment that is understood — this is the only
/// automated check that the diff is actually drawn, and its absence is exactly
/// how the previous renderer shipped blank twice.
@Suite("Diff rendering", .serialized)
@MainActor
struct DiffRenderingTests {

    /// One addition, one deletion and surrounding context, as git emits it.
    private var samplePatch: String {
        """
        diff --git a/src/venue.js b/src/venue.js
        index 83db48f..bf269f4 100644
        --- a/src/venue.js
        +++ b/src/venue.js
        @@ -1,6 +1,7 @@
         export function capacity(venue) {
        -  return venue.seats
        +  // venue capacity fix
        +  return venue.seats + venue.standing
         }

         export default capacity

        """
    }

    private func payload(patch: String, style: DiffPayload.Style = .unified) -> DiffPayload {
        DiffPayload(
            patch: patch,
            fileName: "src/venue.js",
            diffStyle: style,
            generation: 1,
            appearance: .resolved(for: .dark)
        )
    }

    /// Spins the run loop until `condition` holds, or the deadline passes.
    ///
    /// The web view loads, parses and renders asynchronously; without turning
    /// the run loop none of that happens inside a test.
    @discardableResult
    private func spin(
        upTo seconds: TimeInterval, until condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func mount(_ surface: DiffWebSurface, size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = surface.webView
        surface.webView.frame = window.contentView?.bounds ?? .zero
        // Off-screen but ordered in: WebKit does not bring up a WebContent
        // process for a window that was never placed on screen, so without this
        // the page never loads and `ready` never arrives.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        return window
    }

    /// Renders, snapshots, and returns the image plus how many of its pixels are
    /// not the canvas colour.
    private func snapshot(_ surface: DiffWebSurface, named name: String) -> (NSImage?, Int) {
        var image: NSImage?
        var done = false
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        surface.webView.takeSnapshot(with: configuration) { result, _ in
            image = result
            done = true
        }
        spin(upTo: 10) { done }

        guard let image,
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return (image, 0) }

        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(filePath: "/tmp/grove-web-\(name).png"))
        }

        var different = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let red = Int((colour.redComponent * 255).rounded())
                let green = Int((colour.greenComponent * 255).rounded())
                let blue = Int((colour.blueComponent * 255).rounded())
                // 0x0D1117 — the dark canvas the payload asks for.
                if abs(red - 0x0D) + abs(green - 0x11) + abs(blue - 0x17) > 12 { different += 1 }
            }
        }
        return (image, different)
    }

    // MARK: Tests

    @Test("the renderer ships inside the app bundle")
    func rendererIsBundled() throws {
        let root = try #require(
            DiffSchemeHandler.bundledRoot(),
            "DiffRenderer is not in the app bundle — run scripts/web.sh")

        let index = root.appending(path: "index.html")
        #expect(FileManager.default.fileExists(atPath: index.path))

        let assets = try FileManager.default.contentsOfDirectory(
            atPath: root.appending(path: "assets").path)
        #expect(assets.contains { $0.hasPrefix("index-") && $0.hasSuffix(".js") })
    }

    @Test(
        "the page loads and announces itself",
        .disabled("WKWebView does not come up inside the test host — see HANDOFF, \"The diff surface\"")
    )
    func pageBecomesReady() {
        let surface = DiffWebSurface()
        let window = mount(surface, size: NSSize(width: 600, height: 300))

        #expect(spin(upTo: 15) { surface.isReady }, "the renderer never signalled ready")
        _ = window
    }

    /// The one that would have caught both previous failures.
    @Test(
        "a diff is actually painted",
        .disabled("WKWebView does not come up inside the test host — see HANDOFF, \"The diff surface\"")
    )
    func diffIsPainted() {
        let surface = DiffWebSurface()
        var errors: [String] = []
        surface.onError = { errors.append($0) }
        let window = mount(surface, size: NSSize(width: 700, height: 320))

        #expect(spin(upTo: 15) { surface.isReady })
        surface.send(.diff(payload(patch: samplePatch)))

        // Highlighting resolves a grammar chunk asynchronously, so settle before
        // looking.
        spin(upTo: 3) { false }

        let (image, painted) = snapshot(surface, named: "unified")
        #expect(errors.isEmpty, "renderer reported: \(errors)")
        #expect(image != nil, "no snapshot came back")
        #expect(painted > 2000, "the pane is essentially blank — \(painted) non-canvas pixels")
        _ = window
    }

    @Test(
        "an empty patch renders a notice rather than failing",
        .disabled("WKWebView does not come up inside the test host — see HANDOFF, \"The diff surface\"")
    )
    func emptyPatch() {
        let surface = DiffWebSurface()
        var errors: [String] = []
        surface.onError = { errors.append($0) }
        let window = mount(surface, size: NSSize(width: 500, height: 200))

        #expect(spin(upTo: 15) { surface.isReady })
        surface.send(.diff(payload(patch: "")))
        spin(upTo: 2) { false }

        #expect(errors.isEmpty, "renderer reported: \(errors)")
        _ = window
    }

    /// A diff is file contents, which is untrusted input. It reaches the page as
    /// a `callAsyncJavaScript` argument rather than as interpolated script text,
    /// so this must render as code, not execute.
    @Test(
        "a diff containing script syntax is inert",
        .disabled("WKWebView does not come up inside the test host — see HANDOFF, \"The diff surface\"")
    )
    func hostilePatchIsInert() {
        let hostile = """
            diff --git a/x.html b/x.html
            index 1111111..2222222 100644
            --- a/x.html
            +++ b/x.html
            @@ -1,1 +1,2 @@
             <p>hi</p>
            +</script><script>window.grove = null</script>

            """
        let surface = DiffWebSurface()
        var errors: [String] = []
        surface.onError = { errors.append($0) }
        let window = mount(surface, size: NSSize(width: 700, height: 240))

        #expect(spin(upTo: 15) { surface.isReady })
        surface.send(.diff(payload(patch: hostile)))
        spin(upTo: 2) { false }

        // If the payload had escaped its argument, `window.grove` would be gone
        // and this second render would throw.
        surface.send(.diff(payload(patch: samplePatch)))
        spin(upTo: 2) { false }

        let (_, painted) = snapshot(surface, named: "hostile")
        #expect(errors.isEmpty, "renderer reported: \(errors)")
        #expect(painted > 2000, "the second render did not happen — \(painted) pixels")
        _ = window
    }
}
