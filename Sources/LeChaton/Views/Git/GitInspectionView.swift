import LeChatonCore
import SwiftUI

struct GitInspectionView: View {
    let workspace: WorkspaceController
    @State private var selectedPath: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Repository Changes")
                        .font(.headline)
                    Text("Read-only, bounded inspection")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if workspace.git.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await workspace.refreshGit() }
                }
                .tint(LeChatonTheme.orange)
                .disabled(workspace.model.lifecycle != .idle || workspace.git.isLoading)
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            .padding(12)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) {
                Rectangle().fill(LeChatonTheme.accentGradient).frame(height: 1).opacity(0.45)
            }

            if workspace.model.lifecycle != .idle {
                ContentUnavailableView {
                    Label(
                        workspace.model.canResume ? "Resume to inspect changes" : "Git inspection unavailable",
                        systemImage: workspace.model.canResume ? "pause.circle" : "hourglass"
                    )
                } description: {
                    if workspace.model.canResume {
                        Text("Resume the Thread before inspecting repository changes.")
                    } else {
                        Text("Finish the current Thread activity before inspecting repository changes.")
                    }
                } actions: {
                    if workspace.model.canResume {
                        Button("Resume") { Task { await workspace.resume() } }
                            .buttonStyle(.borderedProminent)
                            .tint(LeChatonTheme.orange)
                            .foregroundStyle(LeChatonTheme.onAccent)
                    }
                }
            } else if workspace.git.isLoading {
                ProgressView("Inspecting repository…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = workspace.git.errorMessage {
                ContentUnavailableView {
                    Label("Git inspection failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry Inspection") { Task { await workspace.refreshGit() } }
                }
            } else if let inspection = workspace.git.inspection {
                inspectionBody(inspection)
            } else {
                ContentUnavailableView {
                    Label("Changes not inspected yet", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("Inspect the current working tree for staged, unstaged, and untracked changes.")
                } actions: {
                    Button("Inspect Changes") { Task { await workspace.refreshGit() } }
                        .buttonStyle(.borderedProminent)
                        .tint(LeChatonTheme.orange)
                        .foregroundStyle(LeChatonTheme.onAccent)
                }
            }
        }
        .leChatonDetailCanvas()
        .task(id: workspace.git.baseline != nil) {
            if workspace.model.lifecycle == .idle,
               !workspace.git.isLoading,
               workspace.git.inspection == nil
            {
                await workspace.refreshGit()
            }
        }
    }

    @ViewBuilder
    private func inspectionBody(_ inspection: GitInspection) -> some View {
        if inspection.files.isEmpty {
            ContentUnavailableView(
                "Working tree is clean",
                systemImage: "checkmark.circle",
                description: Text("No staged, unstaged, or untracked paths were reported by Git.")
            )
        } else {
            HSplitView {
                List(inspection.files, selection: $selectedPath) { file in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: statusIcon(file.status))
                                .foregroundStyle(statusColor(file.status))
                                .frame(width: 16)
                            Text(file.status.path)
                                .lineLimit(1)
                            Spacer()
                        }
                        if file.baselineAttribution == .preExisting {
                            Text("Pre-existing")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(file.status.path)
                    .accessibilityLabel(fileAccessibilityLabel(file))
                }
                .frame(minWidth: 220, idealWidth: 270, maxWidth: 340)

                if let selected = selectedFile(in: inspection) {
                    GitFileDiffView(file: selected)
                } else {
                    ContentUnavailableView(
                        "Select a changed file",
                        systemImage: "doc.text.magnifyingglass"
                    )
                }
            }
            .onAppear {
                if selectedPath == nil { selectedPath = inspection.files.first?.status.path }
            }
            .onChange(of: inspection.files.map(\.status.path)) { _, paths in
                if selectedPath == nil || !paths.contains(selectedPath ?? "") {
                    selectedPath = paths.first
                }
            }
        }
    }

    private func selectedFile(in inspection: GitInspection) -> GitFileInspection? {
        inspection.files.first { $0.status.path == selectedPath }
    }

    private func statusIcon(_ status: GitStatusEntry) -> String {
        if status.kind == .untracked { return "doc.badge.plus" }
        if status.isSubmodule { return "shippingbox" }
        if status.hasStagedChange && status.hasUnstagedChange { return "circle.lefthalf.filled" }
        if status.hasStagedChange { return "checkmark.circle" }
        return "pencil.circle"
    }

    private func statusColor(_ status: GitStatusEntry) -> Color {
        if status.kind == .untracked { return LeChatonTheme.coral }
        if status.hasStagedChange { return LeChatonTheme.success }
        return LeChatonTheme.amber
    }

    private func fileAccessibilityLabel(_ file: GitFileInspection) -> String {
        var parts = [file.status.path]
        if file.status.hasStagedChange { parts.append("staged") }
        if file.status.hasUnstagedChange { parts.append("unstaged") }
        if file.baselineAttribution == .preExisting {
            parts.append("pre-existing")
        }
        return parts.joined(separator: ", ")
    }
}

private struct GitFileDiffView: View {
    let file: GitFileInspection

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.status.path)
                        .font(.headline)
                    if let originalPath = file.status.originalPath {
                        Text("Renamed from \(originalPath)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if file.baselineAttribution == .preExisting {
                        Label("Pre-existing", systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(file.sections) { section in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(section.kind.rawValue.capitalized)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        rendered(section.content)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func rendered(_ diff: GitRenderedDiff) -> some View {
        switch diff {
        case let .text(text):
            diffText(text)
        case let .truncated(prefix):
            VStack(alignment: .leading, spacing: 8) {
                diffText(prefix)
                Label("Diff truncated at the per-file safety limit", systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(LeChatonTheme.amber)
            }
        case let .placeholder(placeholder):
            Label(placeholderText(placeholder), systemImage: placeholderIcon(placeholder))
                .foregroundStyle(LeChatonTheme.secondaryText)
                .padding(10)
                .background(LeChatonTheme.utilitySurface, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).stroke(LeChatonTheme.hairline)
                }
        }
    }

    private func diffText(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func placeholderText(_ placeholder: GitDiffPlaceholder) -> String {
        switch placeholder {
        case .binary: "Binary content is not rendered"
        case .submodule: "Submodule content is not expanded"
        case .nonRegularFile: "Non-regular file content is not rendered"
        case let .oversized(byteCount): "File is too large to render (\(byteCount) bytes)"
        case let .gitError(message): "Git could not render this section: \(message)"
        }
    }

    private func placeholderIcon(_ placeholder: GitDiffPlaceholder) -> String {
        switch placeholder {
        case .binary: "doc.zipper"
        case .submodule: "shippingbox"
        case .nonRegularFile: "questionmark.diamond"
        case .oversized: "externaldrive.badge.exclamationmark"
        case .gitError: "exclamationmark.triangle"
        }
    }
}
