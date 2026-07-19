import LeChatonCore
import SwiftUI

struct PermissionRequestSheet: View {
    let workspace: WorkspaceController
    let permission: PendingPermission

    @State private var isSubmitting = false
    @State private var isCancelling = false
    @FocusState private var cancelIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Vibe requests permission", systemImage: "hand.raised.fill")
                .font(.title2.bold())
                .foregroundStyle(LeChatonTheme.amber)

            Text("Tool call \(permission.request.toolCallID) is waiting. Requests are answered in arrival order.")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            VStack(spacing: 10) {
                ForEach(permission.request.options, id: \.optionID) { option in
                    Button {
                        submit(option.optionID)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.name)
                                Text(option.kind)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(LeChatonTheme.orange)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSubmitting || isCancelling)
                    .accessibilityLabel("\(option.name), \(option.kind)")
                    .accessibilityHint("Responds to this permission request exactly once")
                }
            }

            if permission.request.options.isEmpty {
                Label(
                    "Vibe did not provide a permission choice. Cancel the prompt to recover safely.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(LeChatonTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let error = workspace.transientError {
                Label(error, systemImage: "xmark.circle")
                    .font(.callout)
                    .foregroundStyle(LeChatonTheme.danger)
                    .textSelection(.enabled)
                    .accessibilityLabel("Permission response failed: \(error)")
            }

            HStack {
                Button("Cancel Prompt", role: .cancel) { cancelPrompt() }
                    .focused($cancelIsFocused)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCancelling || workspace.model.lifecycle == .cancelling)

                Spacer()

                if isSubmitting || isCancelling {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(isCancelling ? "Cancelling prompt…" : "Sending response…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if isSubmitting {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                    Text("Cancellation still wins if the permission response has not completed.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 440)
        .tint(LeChatonTheme.orange)
        .interactiveDismissDisabled()
        .onAppear { cancelIsFocused = true }
    }

    private func submit(_ optionID: String) {
        guard !isSubmitting, !isCancelling else { return }
        isSubmitting = true
        Task {
            await workspace.resolvePermission(permission, optionID: optionID)
            isSubmitting = false
        }
    }

    private func cancelPrompt() {
        guard !isCancelling else { return }
        isCancelling = true
        Task {
            await workspace.cancelPrompt()
            isCancelling = false
        }
    }
}
