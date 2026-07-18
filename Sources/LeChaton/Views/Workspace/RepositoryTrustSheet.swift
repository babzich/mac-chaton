import LeChatonCore
import SwiftUI

struct RepositoryTrustSheet: View {
    let workspace: WorkspaceController
    let status: VibeRepositoryTrustStatus

    @State private var isApplying = false

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
                Label("Vibe did not advertise a supported trust choice.", systemImage: "xmark.circle")
                    .foregroundStyle(.red)
            }

            HStack {
                if decisions.contains("decline") {
                    Button("Don’t Trust", role: .cancel) { apply("decline") }
                        .disabled(isApplying)
                }
                Spacer()
                ForEach(grantDecisions, id: \.self) { decision in
                    Button(label(for: decision)) { apply(decision) }
                        .buttonStyle(.borderedProminent)
                        .tint(LeChatonTheme.orange)
                        .foregroundStyle(LeChatonTheme.onAccent)
                        .disabled(isApplying)
                }
            }

            if isApplying {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Applying Vibe’s trust decision and creating the Thread…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .tint(LeChatonTheme.orange)
        .accessibilityElement(children: .contain)
    }

    private var decisions: [String] {
        status.options.compactMap(\.stringValue)
    }

    private var grantDecisions: [String] {
        decisions.filter { $0 != "decline" }
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
}
