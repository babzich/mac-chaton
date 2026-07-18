import LeChatonCore
import SwiftUI

struct PermissionRequestSheet: View {
    let workspace: WorkspaceController
    let permission: PendingPermission

    @State private var isSubmitting = false

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
                    .disabled(isSubmitting)
                    .accessibilityHint("Responds to this permission request exactly once")
                }
            }

            if isSubmitting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Sending response…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .tint(LeChatonTheme.orange)
        .interactiveDismissDisabled()
    }

    private func submit(_ optionID: String) {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            await workspace.resolvePermission(permission, optionID: optionID)
            isSubmitting = false
        }
    }
}
