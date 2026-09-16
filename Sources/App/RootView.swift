import SwiftUI

/// Grove's three-column shell.
///
/// The layout follows Tower — sidebar, list, detail — with one change that is
/// the reason Grove exists: Tower is one window per repository, whereas here the
/// **repository is the top-level sidebar item**. Selecting one expands it in
/// place to reveal its sections, and only one repo is expanded at a time, so ten
/// repos still fit in a readable sidebar. Pinned above them is `Overview`, the
/// all-repos-at-once view.
struct RootView: View {
    @State private var selection: SidebarSelection? = .overview
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarColumn(selection: $selection)
                .navigationSplitViewColumnWidth(
                    min: Metrics.sidebarMinWidth,
                    ideal: Metrics.sidebarIdealWidth,
                    max: Metrics.sidebarMaxWidth
                )
        } content: {
            ListColumn(selection: selection)
                .navigationSplitViewColumnWidth(
                    min: Metrics.listMinWidth,
                    ideal: Metrics.listIdealWidth,
                    max: Metrics.listMaxWidth
                )
        } detail: {
            DetailColumn(selection: selection)
        }
        .navigationTitle("Grove")
        .toolbarTitleDisplayMode(.inline)
        // Keeps the sidebar and top bar still while the window is live-resized.
        .windowResizeAnchor(.topLeading)
    }
}

// MARK: - Columns

private struct SidebarColumn: View {
    @Binding var selection: SidebarSelection?

    var body: some View {
        List(selection: $selection) {
            Section("Workspace") {
                Label("Overview", systemImage: "square.grid.2x2")
                    .tag(SidebarSelection.overview)
            }

            Section("Repositories") {
                // Phase 3 replaces this with real discovery against the
                // grove-fixtures workspace.
                Text("No repositories yet")
                    .font(Typography.secondaryDetail)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }
}

private struct ListColumn: View {
    let selection: SidebarSelection?

    var body: some View {
        switch selection {
        case .overview, .none:
            ContentUnavailableView(
                "No Workspace",
                systemImage: "folder.badge.plus",
                description: Text("Choose a folder containing your git repositories.")
            )
        case .repo(_, let section):
            ContentUnavailableView(
                section.title,
                systemImage: section.symbol,
                description: Text("Coming in a later phase.")
            )
        }
    }
}

private struct DetailColumn: View {
    let selection: SidebarSelection?

    var body: some View {
        ContentUnavailableView(
            "No File Selected",
            systemImage: "doc.text",
            description: Text("Select a changed file to view its diff.")
        )
    }
}

#Preview {
    RootView()
        .frame(width: 1280, height: 800)
}
