import Foundation
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
                        HStack(spacing: 6) {
                            Text(workspace.model.threadPresentation?.title ?? "Conversation")
                                .lineLimit(1)

                            if workspace.model.threadPresentation?.isProvisional == true {
                                Text("Draft")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(LeChatonTheme.orange)
                            }
                        }
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
                .help(threadHelp)

                if workspace.model.threadPresentation != nil {
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
        case .switchingProvider: "Switching Provider"
        case .reloadRequired: "Reload required"
        case .cleanupRequired: "Cleanup required"
        case .swapFailed: "Swap failed"
        case .failed: "Failed"
        }
    }

    private var threadHelp: String {
        guard let thread = workspace.model.threadPresentation else {
            return "Start a Thread in a Git repository"
        }
        let state = thread.isProvisional ? "Unsaved draft" : "Saved Thread"
        return "\(state)\n\(thread.cwd)\nVibe session \(thread.vibeSessionID)"
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
                .accessibilityLabel(authenticationAccessibilityLabel)
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
            case .authenticated: Self.localUserDisplayName ?? "Authenticated"
            case .unauthenticated: "Sign-in required"
            case .unknown: "Authentication not checked"
            }
        }
    }

    private var authenticationHelp: String {
        switch workspace.model.authentication {
        case let .status(status) where status.state == .authenticated:
            if let name = Self.localUserDisplayName {
                return "Vibe is authenticated. \(name) is the local macOS account name; Vibe does not expose the signed-in Mistral profile name."
            }
            return "Vibe is authenticated."
        case let .status(status) where status.state == .unauthenticated:
            return "Vibe needs authentication. Open Settings to sign in."
        default:
            return "LeChaton does not start Vibe at launch. Resume a Thread or use Refresh Status in Settings to check authentication."
        }
    }

    private var authenticationAccessibilityLabel: String {
        switch workspace.model.authentication {
        case let .status(status) where status.state == .authenticated:
            "\(authenticationLabel), Vibe authenticated"
        case let .status(status) where status.state == .unauthenticated:
            "Vibe authentication required"
        default:
            "Vibe authentication not checked"
        }
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
            case .untrusted where status.allowsSessionStart: "No trust decision needed"
            case .untrusted: "Trust required in Vibe"
            case .unknown: "Repository trust not checked"
            }
        }
    }

    private var trustHelp: String {
        switch workspace.model.trust {
        case .unknown:
            "Repository trust controls whether Vibe may load project-owned instructions and configuration. LeChaton checks it when starting or resuming a Thread."
        case let .status(status):
            switch status.state {
            case .trusted:
                "This repository is trusted. Vibe may load its project-owned instructions and configuration."
            case .untrusted where status.allowsSessionStart:
                "Vibe found no project-owned instructions or configuration that need a trust decision, so it can continue with project configuration excluded."
            case .untrusted:
                "Trusting permits Vibe to load project-owned instructions and configuration. Vibe owns and stores the decision."
            case .unknown:
                "Vibe returned a repository trust state LeChaton does not recognize. Retry the check or resolve it in Vibe."
            }
        }
    }

    private var trustIcon: String {
        switch workspace.model.trust {
        case let .status(status) where status.state == .trusted: "checkmark.shield"
        case let .status(status) where status.allowsSessionStart: "shield"
        case let .status(status) where status.state == .untrusted: "exclamationmark.shield"
        default: "questionmark.diamond"
        }
    }

    private var trustColor: Color {
        switch workspace.model.trust {
        case let .status(status) where status.state == .trusted: LeChatonTheme.success
        case let .status(status) where status.allowsSessionStart: LeChatonTheme.secondaryText
        case let .status(status) where status.state == .untrusted: LeChatonTheme.amber
        default: LeChatonTheme.secondaryText
        }
    }

    private static let localUserDisplayName: String? = {
        let name = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }()
}
