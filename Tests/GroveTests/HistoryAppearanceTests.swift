import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Grove

/// Renders the history list to a PNG so it can be **looked at**.
///
/// Grove's one real blind spot: the diff surface's pixel tests are disabled
/// because `WKWebView` never comes up inside the test host, and nothing else
/// draws anything a test can read. Every visual change has therefore been
/// verified by building the app, opening it, and asking. That loop is slow and
/// it is how three rounds of "this does not look like the reference" happened.
///
/// `ImageRenderer` needs no window and no web content, so the native half of the
/// window *can* be rasterised here. This writes the real ``HistoryPane`` — the
/// same view the app builds, with a real repository behind it — to a file.
///
/// Opt-in, and it never fails: it is a darkroom, not an assertion. Run it with
///
/// ```
/// GROVE_RENDER=/tmp scripts/test.sh
/// ```
@Suite("History appearance", .serialized)
@MainActor
struct HistoryAppearanceTests {

    /// Where the images land: `.build/render/` beside the project.
    ///
    /// Derived from `#filePath` rather than from the working directory or
    /// `temporaryDirectory`. A test host's temporary directory is a per-process
    /// folder somewhere under `/var/folders`, which is a fine place to write a
    /// file and a hopeless one to go and look at it — the first version of this
    /// wrote two images nobody could find. `.build` is already gitignored.
    private static var outputDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["GROVE_RENDER"] {
            return URL(filePath: override)
        }
        return URL(filePath: #filePath)
            .deletingLastPathComponent()  // GroveTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the project
            .appending(path: ".build/render")
    }

    @Test("renders the commit list for inspection")
    func renderCommitList() async throws {
        let directory = Self.outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let lab = try await Lab.make()
        defer { lab.tearDown() }

        try await lab.populate()

        let model = lab.model
        await model.loadHistory()
        #expect(!model.commits.isEmpty, "nothing to draw")

        // A selected row is half of what is being judged — the accent fill, the
        // badges on top of it, the rail drawn through it.
        if model.commits.count > 3 {
            await model.selectCommit(model.commits[3])
        }

        for scheme in [ColorScheme.dark, .light] {
            // The rows, not `HistoryPane` itself. `ImageRenderer` has no
            // viewport, so a `LazyVStack` inside a `ScrollView` materialises
            // nothing and the first version of this wrote two blank images. The
            // views below are the real ones the pane builds; only the scroller
            // around them is missing, and the scroller is not what is being
            // looked at.
            let view =
                VStack(alignment: .leading, spacing: 0) {
                    MonthHeader(title: "September 2026")

                    ForEach(Array(model.commits.prefix(10).enumerated()), id: \.element.id) {
                        index, commit in
                        CommitRow(
                            commit: commit,
                            row: index < model.graphRows.count ? model.graphRows[index] : nil,
                            isSelected: model.selectedCommit?.oid == commit.oid,
                            onSelect: {}
                        )
                    }
                }
                .frame(width: 400)
                .background(Palette.contentFill.color)
                .environment(\.colorScheme, scheme)

            let renderer = ImageRenderer(content: view)
            // Retina, because the things being judged are hairlines, a 1.5pt
            // ring and 10pt type.
            renderer.scale = 2

            // `Palette` resolves through `NSColor(name:dynamicProvider:)`, which
            // reads the *drawing* appearance and knows nothing about SwiftUI's
            // `colorScheme` environment. Without this both files came out
            // identical, byte for byte.
            let appearance = try #require(
                NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))

            var rendered: NSImage?
            appearance.performAsCurrentDrawingAppearance { rendered = renderer.nsImage }

            let image = try #require(rendered, "ImageRenderer produced nothing")
            let url = directory
                .appending(path: "grove-history-\(scheme == .dark ? "dark" : "light").png")
            try write(image, to: url)
            print("wrote \(url.path())")
        }
    }

    private func write(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }

    // MARK: A repository worth drawing

    /// A small history with the things the row has to cope with: several refs on
    /// one commit, a tag, a long author name, a long subject, and a merge.
    private struct Lab {
        let model: RepoViewModel
        let root: URL

        static func make() async throws -> Lab {
            let root = URL(filePath: NSTemporaryDirectory())
                .appending(path: "grove-appearance-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let environment = await GitEnvironment.resolve()
            let repository = Repository(
                root: root, gitPath: root.appending(path: ".git"), kind: .standard, depth: 0)
            let model = RepoViewModel(
                repository: repository,
                engine: RepoEngine(
                    repository: repository,
                    runner: GitRunner(environment: environment),
                    limiter: GitTaskLimiter(capacity: 4)
                )
            )

            let lab = Lab(model: model, root: root)
            try await lab.git("init", "--initial-branch=main")
            try await lab.git("config", "user.email", "me@emirhanengin.com")
            try await lab.git("config", "user.name", "Emirhan Engin")
            return lab
        }

        func populate() async throws {
            let subjects = [
                "LET'S GOOOO",
                "Refactor code for improved readability and maintainability",
                "Enhance RootView with workspace management features",
                "Add accessibility override support and improve color handling",
                "Implement repository filtering and refresh functionality",
                "Implement display cap for repository changes in UI",
                "Add diff rendering capabilities and related UI enhancements",
                "Implement patch building and selection handling for diffs",
                "Implement live refresh for repository changes using FSEvents",
                "Update Handoff documentation and enhance repository handling",
                "Refactor workspace switcher and enhance repository selection",
                "Implement repository remote operations and enhance error handling",
                "Restructure window chrome and redesign repository navigation",
                "Release 0.2.0",
            ]

            for (index, subject) in subjects.enumerated() {
                try write("file\(index).txt", "v\(index)\n")
                try await git("add", "-A")
                try await git("commit", "-m", subject)

                if index == 4 { try await git("tag", "v0.1.0") }
            }

            try await git("tag", "v0.2.0")
            // A remote-tracking ref, without a remote to talk to: the badge only
            // cares that the ref exists under `refs/remotes/`.
            let head = try await git("rev-parse", "HEAD")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try await git("update-ref", "refs/remotes/origin/main", head)
            try await git("update-ref", "refs/remotes/origin/HEAD", head)

            await model.refreshAndWait()
        }

        @discardableResult
        func git(_ arguments: String...) async throws -> String {
            let environment = await GitEnvironment.resolve()
            let result = try await GitRunner(environment: environment).write(arguments, in: root)
            #expect(result.didSucceed, "git \(arguments.joined(separator: " ")) failed")
            return String(decoding: result.stdout, as: UTF8.self)
        }

        func write(_ name: String, _ contents: String) throws {
            try contents.write(to: root.appending(path: name), atomically: true, encoding: .utf8)
        }

        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }
}
