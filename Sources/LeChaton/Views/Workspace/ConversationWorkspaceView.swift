import LeChatonCore
import SwiftUI

struct ConversationWorkspaceView: View {
    let workspace: WorkspaceController
    let onNewThread: () -> Void
    let onRemoveThread: () -> Void
    let onResetRuntime: () -> Void

    var body: some View {
        Group {
            if let metadata = workspace.model.selectedThread {
                VStack(spacing: 0) {
                    SessionHeaderView(metadata: metadata)

                    if let issue = workspace.model.issue {
                        SessionRecoveryBanner(
                            workspace: workspace,
                            issue: issue,
                            onRemoveThread: onRemoveThread,
                            onResetRuntime: onResetRuntime
                        )
                        .padding(.horizontal)
                        .padding(.top, 10)
                    }

                    sessionContent
                }
            } else {
                ZStack {
                    LeChatonPixelField(opacity: 0.17)
                        .scaleEffect(2.1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(56)

                    VStack(spacing: 0) {
                        if let issue = workspace.model.issue {
                            SessionRecoveryBanner(
                                workspace: workspace,
                                issue: issue,
                                onRemoveThread: onRemoveThread,
                                onResetRuntime: onResetRuntime
                            )
                            .padding()
                        }

                        ContentUnavailableView {
                            VStack(spacing: 16) {
                                LeChatonBrandLockup()
                                Label("Start a Thread", systemImage: "bubble.left.and.text.bubble.right")
                            }
                        } description: {
                            Text("Choose a Git worktree. LeChaton stores only project and Vibe session metadata; Vibe remains the transcript authority.")
                        } actions: {
                            Button("New Thread…", systemImage: "folder.badge.plus", action: onNewThread)
                                .buttonStyle(.borderedProminent)
                                .tint(LeChatonTheme.orange)
                                .foregroundStyle(LeChatonTheme.onAccent)
                                .disabled(!workspace.canCreateThread)
                        }
                    }
                }
            }
        }
        .leChatonDetailCanvas()
    }

    @ViewBuilder
    private var sessionContent: some View {
        switch workspace.model.lifecycle {
        case .unloaded:
            ExplicitResumeView(workspace: workspace, title: "Thread is unloaded")

        case .loadingHistory:
            VStack {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(LeChatonTheme.orange)
                    Text("Loading history from Vibe…")
                        .font(.headline)
                    Text("History is published only after the replay barrier is fully reduced.")
                        .foregroundStyle(LeChatonTheme.secondaryText)
                }
                .padding(26)
                .leChatonGlassCard(cornerRadius: 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)

        case .reloadRequired:
            VStack(spacing: 0) {
                historySurface
                ExplicitResumeBar(workspace: workspace, label: "Resume to reconcile Vibe configuration")
            }

        case .cleanupRequired:
            historySurface
                .disabled(true)

        case .swapFailed:
            VStack(spacing: 0) {
                historySurface
                    .disabled(true)
                if workspace.model.executableCandidate != nil {
                    ExecutableCandidateRecoveryBar()
                }
            }

        case .failed:
            VStack(spacing: 0) {
                historySurface
                if workspace.model.canResume {
                    ExplicitResumeBar(workspace: workspace, label: "Retry Resume")
                }
            }

        default:
            VStack(spacing: 0) {
                historySurface
                if workspace.model.lifecycle == .idle, !workspace.isGitBaselineReady {
                    GitBaselineRequiredBar(workspace: workspace)
                } else {
                    PromptComposerView(workspace: workspace)
                }
            }
        }
    }

    @ViewBuilder
    private var historySurface: some View {
        if workspace.model.sessionState.messages.isEmpty,
           workspace.model.sessionState.reasoning.isEmpty,
           workspace.model.sessionState.toolCalls.isEmpty,
           let snapshot = workspace.model.knownGoodSnapshot
        {
            ZStack(alignment: .topTrailing) {
                TranscriptView(state: snapshot.state)
                    .disabled(true)
                    .opacity(0.58)
                Label(snapshot.label, systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.medium))
                    .padding(8)
                    .glassEffect(.regular)
                    .padding()
            }
            .accessibilityHint("This disabled history is a last-known snapshot, not active runtime state")
        } else {
            TranscriptView(state: workspace.model.sessionState)
        }
    }
}

private struct GitBaselineRequiredBar: View {
    let workspace: WorkspaceController

    var body: some View {
        HStack(spacing: 10) {
            if workspace.git.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(LeChatonTheme.amber)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.git.isLoading ? "Capturing repository baseline…" : "Repository baseline required")
                    .font(.callout.weight(.semibold))
                Text("Prompts stay disabled until the pre-existing Git state is captured.")
                    .font(.caption)
                    .foregroundStyle(LeChatonTheme.secondaryText)
            }
            Spacer()
            if !workspace.git.isLoading {
                Button("Retry Baseline") {
                    Task { await workspace.refreshGit() }
                }
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(LeChatonTheme.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ExecutableCandidateRecoveryBar: View {
    var body: some View {
        HStack {
            Label(
                "The committed executable was revalidated. Review and publish its owner in Settings.",
                systemImage: "checkmark.shield"
            )
            .font(.callout)
            Spacer()
            SettingsLink {
                Text("Review Candidate")
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(LeChatonTheme.hairline).frame(height: 1)
        }
    }
}

private struct SessionHeaderView: View {
    let metadata: SavedThreadMetadata

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(metadata.thread.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(metadata.environment.cwd)
                    .font(.caption.monospaced())
                    .foregroundStyle(LeChatonTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(metadata.thread.vibeSessionID)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .textSelection(.enabled)
                .help("Vibe session ID")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(LeChatonTheme.accentGradient)
                .frame(height: 1)
                .opacity(0.55)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ExplicitResumeView: View {
    let workspace: WorkspaceController
    let title: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "pause.circle")
        } description: {
            Text("No Vibe session process is running. Resume validates the repository, executable, authentication, and trust before replaying history.")
        } actions: {
            Button("Resume", systemImage: "play.fill") {
                Task { await workspace.resume() }
            }
            .buttonStyle(.borderedProminent)
            .tint(LeChatonTheme.orange)
            .foregroundStyle(LeChatonTheme.onAccent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!workspace.model.canResume)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ExplicitResumeBar: View {
    let workspace: WorkspaceController
    let label: String

    var body: some View {
        HStack {
            Label(label, systemImage: "arrow.clockwise")
                .font(.callout)
            Spacer()
            Button("Resume") { Task { await workspace.resume() } }
                .buttonStyle(.borderedProminent)
                .tint(LeChatonTheme.orange)
                .foregroundStyle(LeChatonTheme.onAccent)
                .disabled(!workspace.model.canResume)
        }
        .padding(12)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(LeChatonTheme.hairline).frame(height: 1)
        }
    }
}

private struct PromptComposerView: View {
    let workspace: WorkspaceController
    @State private var prompt = ""
    @FocusState private var promptIsFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Vibe", text: $prompt, axis: .vertical)
                .lineLimit(1 ... 6)
                .textFieldStyle(.roundedBorder)
                .tint(LeChatonTheme.orange)
                .focused($promptIsFocused)
                .disabled(!workspace.canPrompt)
                .accessibilityLabel("Prompt")
                .accessibilityHint("Press Command-Return to send")

            if workspace.model.lifecycle == .prompting || workspace.model.lifecycle == .cancelling {
                Button("Cancel", systemImage: "stop.fill") {
                    Task { await workspace.cancelPrompt() }
                }
                .tint(LeChatonTheme.danger)
                .disabled(workspace.model.lifecycle == .cancelling)
                .keyboardShortcut(.escape, modifiers: [])
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill") { send() }
                    .buttonStyle(.borderedProminent)
                    .tint(LeChatonTheme.orange)
                    .foregroundStyle(LeChatonTheme.onAccent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!workspace.canPrompt || trimmedPrompt.isEmpty)
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(LeChatonTheme.hairline).frame(height: 1)
        }
        .onAppear {
            if workspace.canPrompt { promptIsFocused = true }
        }
        .onChange(of: workspace.canPrompt) { _, canPrompt in
            if canPrompt { promptIsFocused = true }
        }
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        let text = trimmedPrompt
        guard !text.isEmpty else { return }
        prompt = ""
        Task { await workspace.sendPrompt(text) }
    }
}
