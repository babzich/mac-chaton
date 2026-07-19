import LeChatonCore
import SwiftUI

struct RepositoryTrustSheet: View {
    let workspace: WorkspaceController
    let status: VibeRepositoryTrustStatus

    @State private var isApplying = false
    @FocusState private var cancelIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Trust this repository?", systemImage: "exclamationmark.shield")
                .font(.title2.weight(.semibold))
                .foregroundStyle(LeChatonTheme.amber)

            Text("Vibe found project-controlled configuration or instruction files. Trusting allows Vibe to load them while it works in this repository.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let cwd = status.details?["cwd"]?.stringValue {
                LabeledContent("Folder") {
                    Text(cwd)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            if !ignoredFiles.isEmpty {
                GroupBox("Files Vibe will ignore until trusted") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(ignoredFiles, id: \.self) { file in
                            Text(file)
                                .font(.caption.monospaced())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if grantDecisions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Vibe did not advertise a supported trust choice.", systemImage: "xmark.circle")
                        .foregroundStyle(LeChatonTheme.danger)
                    Text("You can resolve trust outside LeChaton and retry the exact interrupted operation, or cancel without sending a decision.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !grantDecisions.isEmpty {
                VStack(spacing: 8) {
                    ForEach(grantDecisions, id: \.self) { decision in
                        Button(label(for: decision)) { apply(decision) }
                            .buttonStyle(.borderedProminent)
                            .tint(LeChatonTheme.orange)
                            .foregroundStyle(LeChatonTheme.onAccent)
                            .frame(maxWidth: .infinity)
                            .disabled(isApplying)
                            .accessibilityHint("Sends this Vibe-advertised trust decision, then retries the interrupted operation")
                    }
                }
            }

            HStack {
                Button("Cancel", role: .cancel) { cancel() }
                    .focused($cancelIsFocused)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isApplying)
                    .accessibilityHint("Abandons this attempt without sending a repository trust decision")

                if decisions.contains("decline") {
                    Button("Don’t Trust") { apply("decline") }
                        .disabled(isApplying)
                        .accessibilityHint("Sends Vibe its advertised decline decision")
                }

                if grantDecisions.isEmpty {
                    Button("Retry Check") { retry() }
                        .disabled(isApplying)
                        .accessibilityHint("Retries the interrupted operation after checking repository trust again")
                }

                Spacer()
            }

            if isApplying {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Applying repository trust action…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .tint(LeChatonTheme.orange)
        .accessibilityElement(children: .contain)
        .interactiveDismissDisabled()
        .onAppear { cancelIsFocused = true }
    }

    private var decisions: [String] {
        status.options.compactMap(\.stringValue)
    }

    private var grantDecisions: [String] {
        decisions.filter { ["trust_repo", "trust_cwd", "trust_session"].contains($0) }
    }

    private var ignoredFiles: [String] {
        status.details?["ignoredFiles"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private func label(for decision: String) -> String {
        switch decision {
        case "trust_repo": "Trust Repository & Continue"
        case "trust_cwd": "Trust This Folder & Continue"
        case "trust_session": "Trust for This Session"
        default: decision.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func apply(_ decision: String) {
        guard !isApplying else { return }
        isApplying = true
        Task {
            await workspace.resolveRepositoryTrust(decision: decision)
            isApplying = false
        }
    }

    private func retry() {
        guard !isApplying else { return }
        isApplying = true
        Task {
            await workspace.retryPendingRepositoryTrust()
            isApplying = false
        }
    }

    private func cancel() {
        guard !isApplying else { return }
        workspace.cancelPendingRepositoryTrust()
    }
}
