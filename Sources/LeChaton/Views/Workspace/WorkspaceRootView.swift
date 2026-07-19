import AppKit
import LeChatonCore
import SwiftUI

struct WorkspaceRootView: View {
    let workspace: WorkspaceController
    let startupRecoveryBackupURL: URL?

    @State private var selection: WorkspaceDestination? = .conversation
    @State private var threadDraft: ThreadCreationDraft?
    @State private var confirmsRemoval = false
    @State private var confirmsDraftDiscard = false
    @State private var confirmsRuntimeReset = false

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebarView(workspace: workspace, selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            detail
        }
        .navigationTitle(workspace.model.threadPresentation?.title ?? "LeChaton")
        .onChange(of: workspace.model.threadPresentation?.id) { _, threadID in
            if threadID == nil {
                selection = .conversation
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let thread = workspace.model.threadPresentation {
                    if thread.isProvisional {
                        Button("Discard Draft", systemImage: "trash") {
                            confirmsDraftDiscard = true
                        }
                        .tint(LeChatonTheme.danger)
                        .disabled(!workspace.canDiscardDraftThread)
                        .help("Stop the provisional Vibe session and discard this unsaved draft")
                    } else {
                        Button("Replace Thread", systemImage: "arrow.triangle.2.circlepath") {
                            chooseRepository(for: .replace)
                        }
                        .disabled(!workspace.canReplaceThread)
                        .help("Replace the saved Thread")

                        Menu("Thread Actions", systemImage: "ellipsis.circle") {
                            Button("Unload Runtime") {
                                Task { await workspace.unload() }
                            }
                            .disabled(!workspace.canUnloadThread)

                            Button("Reset Runtime…") { confirmsRuntimeReset = true }
                                .disabled(!workspace.canResetRuntime)

                            Divider()

                            Button("Remove Saved Thread…", role: .destructive) {
                                confirmsRemoval = true
                            }
                            .disabled(!workspace.canRemoveThread)
                        }
                        .menuIndicator(.hidden)
                        .help("Thread actions")
                    }
                } else {
                    Button("New Thread", systemImage: "plus") { chooseRepository(for: .new) }
                        .tint(LeChatonTheme.orange)
                        .disabled(!workspace.canCreateThread)
                        .help("Create a Thread in a Git repository")
                }

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open Settings")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let backupURL = workspace.model.lastRecoveryBackupURL ?? startupRecoveryBackupURL {
                RecoveryBackupBanner(url: backupURL)
            }
        }
        .sheet(item: $threadDraft) { draft in
            ThreadCreationSheet(draft: draft) { title in
                threadDraft = nil
                Task {
                    switch draft.mode {
                    case .new:
                        await workspace.createThread(repositoryURL: draft.repositoryURL, title: title)
                    case .replace:
                        await workspace.replaceThread(repositoryURL: draft.repositoryURL, title: title)
                    }
                }
            } onCancel: {
                threadDraft = nil
            }
        }
        .sheet(
            isPresented: Binding(
                get: { !workspace.model.pendingPermissions.isEmpty },
                set: { _ in }
            )
        ) {
            if let permission = workspace.model.pendingPermissions.first {
                PermissionRequestSheet(workspace: workspace, permission: permission)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { workspace.model.issue?.kind == .trustRequired && trustStatus != nil },
                set: { _ in }
            )
        ) {
            if let trustStatus {
                RepositoryTrustSheet(workspace: workspace, status: trustStatus)
            }
        }
        .confirmationDialog(
            "Remove the saved Thread?",
            isPresented: $confirmsRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Saved Thread", role: .destructive) {
                Task { await workspace.removeSavedThread() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("LeChaton will forget the Vibe session ID. Vibe’s own session files and repository are not deleted.")
        }
        .confirmationDialog(
            "Discard the draft Thread?",
            isPresented: $confirmsDraftDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard Draft", role: .destructive) {
                Task { await workspace.discardDraftThread() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("LeChaton will stop the provisional Vibe process and forget this unsaved draft. Existing saved Thread metadata, if any, remains available.")
        }
        .confirmationDialog(
            "Reset the runtime?",
            isPresented: $confirmsRuntimeReset,
            titleVisibility: .visible
        ) {
            Button("Reset Runtime") {
                Task { await workspace.resetRuntime() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Transient output, plans, permissions, and the current process are cleared. Saved Thread metadata remains available for Resume.")
        }
        .alert(
            "Action Failed",
            isPresented: Binding(
                get: { workspace.transientError != nil },
                set: { if !$0 { workspace.dismissTransientError() } }
            )
        ) {
            Button("OK") { workspace.dismissTransientError() }
        } message: {
            Text(workspace.transientError ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .conversation {
        case .conversation:
            ConversationWorkspaceView(
                workspace: workspace,
                onNewThread: { chooseRepository(for: .new) },
                onRemoveThread: { confirmsRemoval = true },
                onDiscardDraft: { confirmsDraftDiscard = true },
                onResetRuntime: { confirmsRuntimeReset = true }
            )
        case .changes:
            GitInspectionView(workspace: workspace)
        }
    }

    private var trustStatus: VibeRepositoryTrustStatus? {
        guard case let .status(status) = workspace.model.trust else { return nil }
        return status
    }

    private func chooseRepository(for mode: ThreadCreationMode) {
        switch mode {
        case .new where !workspace.canCreateThread:
            return
        case .replace where !workspace.canReplaceThread:
            return
        default:
            break
        }
        guard let repositoryURL = SystemPickers.chooseRepository() else { return }
        threadDraft = ThreadCreationDraft(
            mode: mode,
            repositoryURL: repositoryURL,
            title: repositoryURL.lastPathComponent
        )
    }
}

private struct RecoveryBackupBanner: View {
    let url: URL

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.green)
            Text("Previous metadata is recoverable at \(url.path)")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
    }
}
