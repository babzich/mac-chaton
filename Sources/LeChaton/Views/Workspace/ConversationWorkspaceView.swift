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
                    SessionHeaderView(metadata: metadata, lifecycle: workspace.model.lifecycle)

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
                                .keyboardShortcut("n")
                                .disabled(workspace.model.issue?.kind == .database)
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

        case .cleanupRequired, .swapFailed:
            historySurface
                .disabled(true)

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
                PromptComposerView(workspace: workspace)
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

private struct SessionHeaderView: View {
    let metadata: SavedThreadMetadata
    let lifecycle: SessionLifecycle

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

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Vibe", text: $prompt, axis: .vertical)
                .lineLimit(1 ... 6)
                .textFieldStyle(.roundedBorder)
                .tint(LeChatonTheme.orange)
                .disabled(!workspace.model.canPrompt)
                .accessibilityLabel("Prompt")

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
                    .disabled(!workspace.model.canPrompt || trimmedPrompt.isEmpty)
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(LeChatonTheme.hairline).frame(height: 1)
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
