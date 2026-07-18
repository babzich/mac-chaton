import SwiftUI

struct ThreadCreationSheet: View {
    let draft: ThreadCreationDraft
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var title: String

    init(
        draft: ThreadCreationDraft,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.draft = draft
        self.onCommit = onCommit
        self.onCancel = onCancel
        _title = State(initialValue: draft.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(draft.mode == .new ? "New Thread" : "Replace Saved Thread")
                .font(.title2.bold())

            Text(draft.repositoryURL.path)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            TextField("Thread title", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Thread title")

            if draft.mode == .replace {
                Label(
                    "The current runtime is stopped before the replacement session is created.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(draft.mode == .new ? "Create Thread" : "Replace Thread") {
                    onCommit(title.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .buttonStyle(.borderedProminent)
                .tint(draft.mode == .replace ? LeChatonTheme.coral : LeChatonTheme.orange)
                .foregroundStyle(LeChatonTheme.onAccent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}
