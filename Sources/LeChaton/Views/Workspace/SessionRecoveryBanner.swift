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

            HStack(spacing: 8) {
                ForEach(visibleActions, id: \.self) { action in
                    actionControl(action)
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
        issue.actions.filter { $0 != .resetLocalMetadata }
    }

    private func label(for action: SessionRecoveryAction) -> String {
        switch action {
        case .retry: "Retry"
        case .resetRuntime: "Reset Runtime"
        case .removeSavedThread: "Remove Saved Thread"
        case .retryCleanup: "Retry Cleanup"
        case .retryCandidate: "Open Settings"
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
            Task { await workspace.resetRuntime() }
        case .removeSavedThread:
            onRemoveThread()
        case .retryCandidate:
            break
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
