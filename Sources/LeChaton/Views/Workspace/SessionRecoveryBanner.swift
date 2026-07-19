import AppKit
import LeChatonCore
import SwiftUI

struct SessionRecoveryBanner: View {
    let workspace: WorkspaceController
    let issue: SessionModelIssue
    let onRemoveThread: () -> Void
    let onResetRuntime: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(issue.title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(LeChatonTheme.danger)

            Text(issue.message)
                .font(.callout)
                .foregroundStyle(LeChatonTheme.secondaryText)
                .textSelection(.enabled)

            if issue.kind == .authenticationRequired {
                CurrentAuthenticationRecoveryControls(workspace: workspace)
            }

            if !visibleActions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(visibleActions, id: \.self) { action in
                        actionControl(action)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .leChatonGlassCard(cornerRadius: 14)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func actionControl(_ action: SessionRecoveryAction) -> some View {
        if action == .retryCandidate {
            Button("Retry Candidate") {
                Task { await workspace.retryExecutableCandidate() }
            }
            SettingsLink {
                Text("Open Settings")
            }
        } else {
            Button(label(for: action), role: role(for: action)) {
                perform(action)
            }
        }
    }

    private var icon: String {
        switch issue.kind {
        case .authenticationRequired: "person.crop.circle.badge.exclamationmark"
        case .trustRequired: "exclamationmark.shield"
        case .repositoryUnavailable: "folder.badge.questionmark"
        case .cleanupRequired, .swapFailed: "exclamationmark.triangle"
        case .configurationReloadRequired: "arrow.clockwise.circle"
        case .database, .persistence: "externaldrive.badge.exclamationmark"
        case .runtime: "bolt.trianglebadge.exclamationmark"
        }
    }

    /// Destructive metadata recovery is only exposed by the typed startup
    /// corruption/migration screen, never while a healthy store is open.
    private var visibleActions: [SessionRecoveryAction] {
        issue.actions.filter { action in
            guard action != .resetLocalMetadata else { return false }
            if action == .retry,
               workspace.model.selectedThread == nil,
               issue.kind != .database
            {
                return false
            }
            if action == .removeSavedThread, workspace.model.selectedThread == nil {
                return false
            }
            return true
        }
    }

    private func label(for action: SessionRecoveryAction) -> String {
        switch action {
        case .retry: "Retry"
        case .resetRuntime: "Reset Runtime"
        case .removeSavedThread: "Remove Saved Thread"
        case .retryCleanup: "Retry Cleanup"
        case .retryCandidate: "Retry Candidate"
        case .resetLocalMetadata: "Reset Local Metadata"
        case .revealDatabase: "Reveal Database"
        case .exportDiagnostic: "Export Diagnostic"
        case .updateApplication: "Update Application"
        case .quit: "Quit"
        }
    }

    private func role(for action: SessionRecoveryAction) -> ButtonRole? {
        switch action {
        case .removeSavedThread, .resetLocalMetadata: .destructive
        default: nil
        }
    }

    private func perform(_ action: SessionRecoveryAction) {
        switch action {
        case .retry:
            Task { await workspace.retryCurrentIssue() }
        case .resetRuntime:
            onResetRuntime()
        case .retryCleanup:
            Task { await workspace.retryCleanup() }
        case .removeSavedThread:
            onRemoveThread()
        case .retryCandidate:
            Task { await workspace.retryExecutableCandidate() }
        case .resetLocalMetadata:
            break
        case .revealDatabase:
            workspace.revealDatabase()
        case .exportDiagnostic:
            workspace.exportDiagnostic()
        case .updateApplication:
            workspace.showUpdateInstructions()
        case .quit:
            NSApp.terminate(nil)
        }
    }
}

private struct CurrentAuthenticationRecoveryControls: View {
    let workspace: WorkspaceController

    var body: some View {
        HStack(spacing: 8) {
            if let attempt = workspace.model.currentAuthenticationAttempt {
                Link("Open Sign-In Page", destination: attempt.signInURL)
                Button("I Finished Signing In") {
                    Task {
                        await workspace.completeCurrentAuthentication(attemptID: attempt.id)
                    }
                }
                .disabled(isBusy)
            } else {
                Button("Sign In…") {
                    Task { await workspace.startCurrentAuthentication() }
                }
                .buttonStyle(.borderedProminent)
                .tint(LeChatonTheme.orange)
                .foregroundStyle(LeChatonTheme.onAccent)
                .disabled(isBusy)
            }

            SettingsLink {
                Text("Open Settings")
            }

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Authentication in progress")
            }
        }
    }

    private var isBusy: Bool {
        workspace.model.lifecycle == .validatingExecutable
            || workspace.model.lifecycle == .swappingExecutable
    }
}
