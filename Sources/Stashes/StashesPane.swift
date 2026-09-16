import SwiftUI

/// The Stashes section: what is put aside, and the four things that can be done
/// with it.
struct StashesPane: View {
    let repo: RepoViewModel

    @State private var isNaming = false
    @State private var message = ""
    @State private var includeUntracked = true
    @State private var keepIndex = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if repo.stashes.isEmpty {
                    ContentUnavailableView(
                        "No stashes",
                        systemImage: "tray",
                        description: Text("Put changes aside without committing them.")
                    )
                    .padding(.top, Space.xxxl)
                } else {
                    ForEach(repo.stashes) { stash in
                        StashRow(
                            stash: stash,
                            isSelected: repo.selectedStash?.oid == stash.oid,
                            isBusy: repo.isBusy,
                            onSelect: { repo.selectedStash = stash },
                            onApply: { repo.applyStash(stash) },
                            onPop: { repo.popStash(stash) },
                            onDrop: { repo.pendingStashDrop = stash }
                        )
                        .padding(.horizontal, Space.lg)
                    }
                }

                if repo.selectedStash != nil, !repo.selectedStashChanges.isEmpty {
                    GroupLabelRow(
                        title: "In this stash",
                        count: repo.selectedStashChanges.count,
                        shown: repo.selectedStashChanges.count
                    )
                    .padding(.horizontal, Space.lg)

                    ForEach(repo.selectedStashChanges) { change in
                        ChangeRow(
                            change: change,
                            staged: true,
                            isSelected: repo.selectedStashChange?.pathBytes == change.pathBytes,
                            onSelect: { repo.selectedStashChange = change }
                        )
                        .padding(.horizontal, Space.lg)
                    }
                }
            }
            .padding(.bottom, Space.md)
        }
        .scrollEdgeEffectStyle(.hard, for: .top)
        .safeAreaBar(edge: .top, spacing: 0) { toolbar }
        .task(id: repo.status.headOID) { await repo.reloadStashes() }
        .task(id: repo.status.dirtyCount) { await repo.reloadStashes() }
        .task(id: repo.selectedStash?.oid) {
            guard let stash = repo.selectedStash else { return }
            await repo.loadStashChanges(stash)
        }
        .alert("Stash Changes", isPresented: $isNaming) {
            TextField("Message (optional)", text: $message)
            Toggle("Include untracked files", isOn: $includeUntracked)
            Toggle("Keep staged changes staged", isOn: $keepIndex)
            Button("Stash") {
                repo.createStash(
                    message: message, includeUntracked: includeUntracked, keepIndex: keepIndex)
                message = ""
            }
            Button("Cancel", role: .cancel) { message = "" }
        } message: {
            // Untracked files are the trap: `git stash` leaves them behind by
            // default, and a later `git clean` eats them.
            Text("Untracked files are not stashed unless you say so.")
        }
        .confirmationDialog(
            "Drop this stash?",
            isPresented: dropPresented,
            titleVisibility: .visible,
            presenting: repo.pendingStashDrop
        ) { stash in
            Button("Drop", role: .destructive) { repo.confirmStashDrop() }
            Button("Cancel", role: .cancel) { repo.pendingStashDrop = nil }
        } message: { stash in
            Text(
                """
                \(stash.message)

                The commit survives until git collects it, so it can still be \
                recovered with:
                git stash apply \(stash.oid)
                """)
        }
    }

    private var dropPresented: Binding<Bool> {
        Binding(
            get: { repo.pendingStashDrop != nil },
            set: { if !$0 { repo.pendingStashDrop = nil } })
    }

    private var toolbar: some View {
        HStack(spacing: Space.md) {
            Text(repo.stashes.isEmpty ? "Nothing stashed" : "\(repo.stashes.count) stashed")
                .font(Typography.secondaryDetail)
                .foregroundStyle(.secondary)

            Spacer(minLength: Space.md)

            Button("Stash Changes…", systemImage: "tray.and.arrow.down") { isNaming = true }
                .labelStyle(.titleAndIcon)
                .disabled(!repo.canStash)
                .help(repo.canStash ? "Put the working copy aside" : "Nothing to stash")
        }
        .padding(.horizontal, Space.lg)
        .frame(height: Metrics.accessoryBar)
        .background(.bar)
    }
}

private struct StashRow: View {
    let stash: StashEntry
    let isSelected: Bool
    let isBusy: Bool
    let onSelect: () -> Void
    let onApply: () -> Void
    let onPop: () -> Void
    let onDrop: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "tray")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(stash.message.isEmpty ? stash.selector : stash.message)
                .font(Typography.fileName)
                .lineLimit(1)
                .truncationMode(.tail)

            if let branch = stash.branch {
                BranchPill(label: branch, isDetached: false)
            }

            Spacer(minLength: Space.sm)

            if isHovered {
                Button("Apply", action: onApply).disabled(isBusy)
                Button("Pop", action: onPop).disabled(isBusy)
                Button("Drop", role: .destructive, action: onDrop).disabled(isBusy)
            } else if let date = stash.date {
                Text(date, format: .relative(presentation: .numeric))
                    .font(Typography.secondaryDetail.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .font(Typography.secondaryDetail)
        .frame(height: Metrics.fileRow)
        .padding(.horizontal, Space.xs)
        .background {
            if isSelected { RoundedRectangle(cornerRadius: Radius.sm).fill(.selection) }
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onSelect)
        .help("\(stash.selector) · \(stash.oid)")
    }
}
