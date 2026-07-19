import LeChatonCore
import SwiftUI

struct WorkspaceSidebarView: View {
    let workspace: WorkspaceController
    @Binding var selection: WorkspaceDestination?

    var body: some View {
        List(selection: $selection) {
            Section("Workspace") {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workspace.model.selectedThread?.thread.title ?? "Conversation")
                            .lineLimit(1)
                        Text(lifecycleLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } icon: {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .foregroundStyle(LeChatonTheme.orange)
                }
                .tag(WorkspaceDestination.conversation)

                if workspace.model.selectedThread != nil {
                    Label("Repository Changes", systemImage: "arrow.triangle.branch")
                        .tag(WorkspaceDestination.changes)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            RuntimeStatusView(workspace: workspace)
                .padding(12)
        }
    }

    private var lifecycleLabel: String {
        switch workspace.model.lifecycle {
        case .unloaded: "Unloaded"
        case .loadingHistory: "Loading history"
        case .idle: "Ready"
        case .prompting: "Vibe is working"
        case .cancelling: "Cancelling"
        case .replacingThread: "Replacing Thread"
        case .validatingExecutable: "Validating Vibe"
        case .swappingExecutable: "Swapping Vibe"
        case .reloadRequired: "Reload required"
        case .cleanupRequired: "Cleanup required"
        case .swapFailed: "Swap failed"
        case .failed: "Failed"
        }
    }
}

private struct RuntimeStatusView: View {
    let workspace: WorkspaceController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LeChatonBrandLockup()
                .padding(.bottom, 3)

            Label(authenticationLabel, systemImage: authenticationIcon)
                .foregroundStyle(authenticationColor)
                .help(authenticationHelp)
            Label(trustLabel, systemImage: trustIcon)
                .foregroundStyle(trustColor)
                .help(trustHelp)

            if let activity = workspace.model.activity {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(LeChatonTheme.orange)
                    Text(activity)
                        .lineLimit(2)
                }
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var authenticationLabel: String {
        switch workspace.model.authentication {
        case .unknown: "Authentication not checked"
        case let .status(status):
            switch status.state {
            case .authenticated: "Authenticated"
            case .unauthenticated: "Sign-in required"
            case .unknown: "Authentication not checked"
            }
        }
    }

    private var authenticationHelp: String {
        "LeChaton does not start Vibe at launch. Resume a Thread or use Refresh Status in Settings to check authentication."
    }

    private var authenticationIcon: String {
        switch workspace.model.authentication {
        case let .status(status) where status.isAuthenticated == true: "person.crop.circle.badge.checkmark"
        case let .status(status) where status.isAuthenticated == false: "person.crop.circle.badge.exclamationmark"
        default: "person.crop.circle.badge.questionmark"
        }
    }

    private var authenticationColor: Color {
        switch workspace.model.authentication {
        case let .status(status) where status.isAuthenticated == true: LeChatonTheme.success
        case let .status(status) where status.isAuthenticated == false: LeChatonTheme.amber
        default: LeChatonTheme.secondaryText
        }
    }

    private var trustLabel: String {
        switch workspace.model.trust {
        case .unknown: "Repository trust not checked"
        case let .status(status):
            switch status.state {
            case .trusted: "Repository trusted"
            case .untrusted: "Trust required in Vibe"
            case .unknown: "Repository trust not checked"
            }
        }
    }

    private var trustHelp: String {
        "Repository trust is checked only when LeChaton starts or resumes a Vibe session."
    }

    private var trustIcon: String {
        switch workspace.model.trust {
        case let .status(status) where status.state == .trusted: "checkmark.shield"
        case let .status(status) where status.state == .untrusted: "exclamationmark.shield"
        default: "questionmark.diamond"
        }
    }

    private var trustColor: Color {
        switch workspace.model.trust {
        case let .status(status) where status.state == .trusted: LeChatonTheme.success
        case let .status(status) where status.state == .untrusted: LeChatonTheme.amber
        default: LeChatonTheme.secondaryText
        }
    }
}
