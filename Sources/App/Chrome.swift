import SwiftUI

/// The second toolbar row: what the workspace is scoped to.
///
/// Lives in `ToolbarItemPlacement.accessoryBar`, which is a real second row in
/// the window's title bar, so it sits *inside* the system's shared background
/// rather than floating over content. That is why it is deliberately **not**
/// glass — stacking our own material on the title bar's would just look muddy.
struct RepoScopeBar: View {
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: Space.lg) {
            Picker("Scope", selection: $workspace.scope) {
                ForEach(RepoScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if workspace.isFiltering, workspace.hiddenRepoCount > 0 {
                Text("\(workspace.hiddenRepoCount) hidden")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .frame(height: Metrics.accessoryBar)
    }
}

/// The bar pinned to the bottom of the detail column.
///
/// Attached with `safeAreaBar(edge:)` rather than a `VStack` + `overlay`, and
/// deliberately not `.toolbar` — macOS has no `bottomBar` placement, that is
/// iOS/watchOS only. `safeAreaBar` also insets the scroll content above it, so
/// the last row stays reachable instead of hiding under the glass, and it
/// participates in the scroll edge effect.
struct GlobalActionBar: View {
    let workspace: WorkspaceModel?
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: Space.lg) {
            HStack(spacing: Space.lg) {
                statusLabel

                Spacer(minLength: Space.xl)

                Button {
                    onRefresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .symbolEffect(.rotate, isActive: isRefreshing)
                }
                .buttonStyle(.plain)
                .help("Refresh all repositories (⌘R)")
                .disabled(workspace == nil)
            }
            .padding(.horizontal, Space.xl)
            .frame(height: Metrics.bar)
            .appGlass(in: .capsule)
        }
        .padding(.horizontal, Space.lg)
        .padding(.bottom, Space.md)
    }

    @ViewBuilder
    private var statusLabel: some View {
        if let workspace {
            HStack(spacing: Space.sm) {
                // Failures are reported here rather than as an alert: a
                // background fetch that fails across ten repositories must not
                // produce ten modal interruptions.
                if workspace.failedRepoCount > 0 {
                    Label(
                        "\(workspace.failedRepoCount) failed",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(Palette.attention.color)
                }

                Text(summary(for: workspace))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        } else {
            Text("No workspace")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func summary(for workspace: WorkspaceModel) -> String {
        switch workspace.discoveryState {
        case .scanning: "Scanning…"
        case .failed(let message): message
        case .idle: ""
        case .ready(let count):
            {
                let repos = count == 1 ? "1 repo" : "\(count) repos"
                let dirty = workspace.totalDirtyCount
                return dirty == 0 ? "\(repos) · clean" : "\(repos) · \(dirty) changes"
            }()
        }
    }
}
