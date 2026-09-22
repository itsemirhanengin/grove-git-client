import SwiftUI

/// The sidebar's header: which workspace is open, and how to open another.
///
/// It was a floating glass pill with a hand-built dropdown, an overlay, a
/// dismiss-catcher and its own animation — roughly 190 lines to reimplement a
/// menu. It is now a menu. What that buys, beyond deleting the code, is the
/// thing this redesign is about: the pill floated over the list, so the sidebar
/// had no top edge and nothing for the other columns' headers to line up with.
/// Flattened into a ``PaneHeader`` it is the left end of a header band that runs
/// unbroken across the window.
struct WorkspaceSwitcher: View {
    let model: AppModel

    private var others: [URL] {
        model.recentWorkspaces.filter { $0.path() != model.workspace?.root.path() }
    }

    var body: some View {
        PaneHeader {
            Menu {
                if !others.isEmpty {
                    Section("Recent") {
                        ForEach(others, id: \.self) { url in
                            Button(url.lastPathComponent) {
                                Task { await model.open(url) }
                            }
                            .help(url.path(percentEncoded: false))
                        }
                    }

                    Section {
                        Menu("Forget") {
                            ForEach(others, id: \.self) { url in
                                Button(url.lastPathComponent) { model.forgetWorkspace(url) }
                            }
                        }
                    }
                }

                Section {
                    Button("Open Workspace…") {
                        Task { await model.chooseWorkspace() }
                    }
                    .keyboardShortcut("o", modifiers: .command)
                }
            } label: {
                HStack(spacing: Space.sm) {
                    Image(systemName: "folder")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Text(model.workspace?.name ?? "No Workspace")
                        .font(Typography.repoName)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: Space.sm)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("Workspace")
            .accessibilityValue(model.workspace?.name ?? "None")
            .help(model.workspace?.root.path() ?? "Choose a folder of repositories")
        }
    }
}
