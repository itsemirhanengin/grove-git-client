import SwiftUI

/// The Branches section: what exists, what is checked out, and what is ahead or
/// behind its upstream.
///
/// `ScrollView` + `LazyVStack` rather than `List`, for the same reason as the
/// Overview: the rows arrive when `for-each-ref` returns, so the row count
/// changes after the view is already on screen, and driving an `NSTableView`
/// that way trips AppKit's reentrant delegate check.
struct BranchesPane: View {
    let repo: RepoViewModel

    @State private var isNamingBranch = false
    @State private var newBranchName = ""

    private var local: [BranchInfo] { repo.branches.filter(\.isLocal) }
    private var remote: [BranchInfo] { repo.branches.filter(\.isRemote) }
    private var current: BranchInfo? { repo.branches.first(where: \.isHead) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if repo.branches.isEmpty {
                    ContentUnavailableView(
                        "No branches",
                        systemImage: "arrow.triangle.branch",
                        description: Text("This repository has no commits yet.")
                    )
                    .padding(.top, Space.xxxl)
                } else {
                    section("Local", local)
                    section("Remote", remote)
                }
            }
            .padding(.bottom, Space.xl)
        }
        .scrollEdgeEffectStyle(.hard, for: .top)
        .safeAreaBar(edge: .top, spacing: 0) { toolbar }
        // Reloaded rather than `loadBranchesIfNeeded`: ahead/behind and the
        // current marker are all stale the moment anything touches HEAD.
        .task(id: repo.status.headOID) { await repo.reloadBranches() }
        .alert("New Branch", isPresented: $isNamingBranch) {
            TextField("Name", text: $newBranchName)
            Button("Create") {
                repo.createBranch(named: newBranchName)
                newBranchName = ""
            }
            Button("Cancel", role: .cancel) { newBranchName = "" }
        } message: {
            Text("Created from \(current?.name ?? "HEAD") and checked out.")
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: Space.md) {
            Text(current.map { "On \($0.name)" } ?? repo.branchLabel)
                .font(Typography.secondaryDetail)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: Space.md)

            Button("New Branch…", systemImage: "plus") { isNamingBranch = true }
                .labelStyle(.titleAndIcon)
                .disabled(repo.isBusy || repo.status.isUnborn)
        }
        .padding(.horizontal, Space.lg)
        .frame(height: Metrics.accessoryBar)
        .background(.bar)
    }

    // MARK: Rows

    @ViewBuilder
    private func section(_ title: String, _ branches: [BranchInfo]) -> some View {
        if !branches.isEmpty {
            Section {
                ForEach(branches) { branch in
                    BranchRow(
                        branch: branch,
                        current: current,
                        isBusy: repo.isBusy,
                        onSwitch: { repo.switchTo(branch) },
                        onMerge: { repo.merge(branch) }
                    )
                    .padding(.horizontal, Space.lg)
                }
            } header: {
                GroupLabelRow(title: title, count: branches.count, shown: branches.count)
                    .padding(.horizontal, Space.lg)
                    .background(.bar)
            }
        }
    }
}

/// One branch.
private struct BranchRow: View {
    let branch: BranchInfo
    let current: BranchInfo?
    let isBusy: Bool
    let onSwitch: () -> Void
    let onMerge: () -> Void

    @State private var isHovered = false

    private var isCurrent: Bool { branch.isHead }

    /// Merging a branch into itself is a no-op git will happily perform.
    private var canMerge: Bool { !isCurrent && current != nil && !isBusy }

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
                .font(.caption)
                // The accent, not green: green means *added* in this palette,
                // and "checked out" is not an addition.
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

            Text(branch.name)
                .font(Typography.fileName)
                .fontWeight(isCurrent ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(branch.shortOID)
                .font(Typography.keyHint)
                .foregroundStyle(.tertiary)

            Spacer(minLength: Space.xs)

            AheadBehindBadge(ahead: branch.ahead, behind: branch.behind)

            if isHovered && !isCurrent {
                Button("Switch", action: onSwitch)
                    .buttonStyle(.plain)
                    .font(Typography.secondaryDetail)
                    .foregroundStyle(.tint)
                    .disabled(isBusy)
            }
        }
        .frame(height: Metrics.fileRow)
        .padding(.horizontal, Space.xs)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { if !isCurrent && !isBusy { onSwitch() } }
        .contextMenu {
            Button("Switch to \(branch.name)", action: onSwitch)
                .disabled(isCurrent || isBusy)
            if let current, canMerge {
                Button("Merge into \(current.name)", action: onMerge)
            }
        }
        .help(branch.refName)
    }
}
