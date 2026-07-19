import LeChatonCore
import SwiftUI

struct SettingsRootView: View {
    let container: ApplicationContainer
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch container.startupState {
            case .starting:
                ProgressView("Opening local metadata…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(failure):
                ContentUnavailableView {
                    Label(failure.title, systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Resolve this issue in the LeChaton workspace window.")
                } actions: {
                    Button("Open Workspace") { openWindow(id: "main") }
                        .buttonStyle(.borderedProminent)
                }
            case .ready:
                if let workspace = container.workspace {
                    LeChatonSettingsView(workspace: workspace)
                } else {
                    ProgressView()
                }
            }
        }
        .frame(width: 560, height: 470)
    }
}

struct LeChatonSettingsView: View {
    let workspace: WorkspaceController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TabView {
            executableSettings
                .tabItem { Label("Vibe", systemImage: "terminal") }

            configurationSettings
                .tabItem { Label("Model", systemImage: "slider.horizontal.3") }
        }
        .scenePadding()
        .tint(LeChatonTheme.orange)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let error = workspace.transientError {
                SettingsErrorBar(workspace: workspace, message: error)
            }
        }
    }

    private var executableSettings: some View {
        Form {
            Section {
                HStack {
                    LeChatonBrandLockup()
                    Spacer()
                    Text("Vibe \(VibeCompatibility.supportedVersion)")
                        .font(.caption.monospaced())
                        .foregroundStyle(LeChatonTheme.secondaryText)
                }
            }

            Section("Mistral Vibe executable") {
                LabeledContent("Current path") {
                    Text(workspace.model.selectedVibePath ?? "Automatically located")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                LabeledContent("Required version", value: VibeCompatibility.supportedVersion)
                LabeledContent(
                    "ACP protocol",
                    value: String(VibeCompatibility.supportedProtocolVersion)
                )

                HStack {
                    Button("Choose and Validate…") {
                        guard let url = SystemPickers.chooseVibeExecutable() else { return }
                        Task { await workspace.validateExecutable(url) }
                    }
                    .disabled(!canValidateExecutable)

                    if workspace.model.lifecycle == .validatingExecutable {
                        ProgressView()
                            .controlSize(.small)
                        Text(workspace.model.activity ?? "Validating…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Current owner status") {
                LabeledContent("Authentication", value: currentAuthenticationLabel)
                Text("Executable validation uses a private authentication process. It never becomes the session runtime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CurrentAuthenticationControls(workspace: workspace)
            }

            if let candidate = workspace.model.executableCandidate {
                ExecutableCandidateView(workspace: workspace, candidate: candidate)
            }

            if let issue = workspace.model.issue {
                Section("Attention") {
                    Label(issue.title, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(LeChatonTheme.danger)
                    Text(issue.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Open Workspace") { openWindow(id: "main") }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var configurationSettings: some View {
        Form {
            Section("Model and thinking") {
                if workspace.model.lifecycle != .idle {
                    ContentUnavailableView {
                        Label("Load an idle Thread", systemImage: "pause.circle")
                    } description: {
                        Text("Resume the saved Thread before changing Vibe configuration.")
                    } actions: {
                        Button("Open Workspace") { openWindow(id: "main") }
                    }
                    .frame(minHeight: 180)
                } else if configurationOptions.isEmpty {
                    ContentUnavailableView(
                        "No model controls advertised",
                        systemImage: "slider.horizontal.below.rectangle",
                        description: Text("Vibe did not advertise a supported model or thinking option for this session.")
                    )
                    .frame(minHeight: 180)
                } else {
                    ForEach(configurationOptions, id: \.id) { option in
                        ConfigurationOptionView(
                            option: option,
                            isApplying: isApplyingConfiguration
                        ) { value in
                            Task {
                                await workspace.applyConfiguration(optionID: option.id, value: value)
                            }
                        }
                    }

                    if isApplyingConfiguration {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(workspace.model.activity ?? "Applying and reloading from Vibe…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if case let .reloadRequired(optionID, requestedValue) = workspace.model.configurationState {
                Section("Reload required") {
                    Label(
                        "Vibe may have retained \(optionID) = \(displayValue(requestedValue)). Resume in the workspace to re-query the effective value.",
                        systemImage: "arrow.clockwise.circle"
                    )
                    .foregroundStyle(.orange)
                    Button("Open Workspace to Resume") { openWindow(id: "main") }
                }
            }

            Section {
                Text("LeChaton publishes only values re-observed from a fresh Vibe load. It does not claim rollback after a timeout or reload failure.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var canValidateExecutable: Bool {
        switch workspace.model.lifecycle {
        case .unloaded, .idle, .swapFailed:
            return true
        default:
            return false
        }
    }

    private var currentAuthenticationLabel: String {
        switch workspace.model.authentication {
        case .unknown: "Unknown"
        case let .status(status): authenticationLabel(status)
        }
    }

    private var configurationOptions: [VibeConfigurationOption] {
        workspace.model.configurationOptions.filter { option in
            let searchable = "\(option.id) \(option.name ?? "")".lowercased()
            return searchable.contains("model") || searchable.contains("thinking")
        }
    }

    private var isApplyingConfiguration: Bool {
        workspace.model.configurationState != .effectiveFromVibe
    }
}

private struct SettingsErrorBar: View {
    let workspace: WorkspaceController
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Label("Action failed", systemImage: "xmark.circle")
                .font(.callout.weight(.semibold))
                .foregroundStyle(LeChatonTheme.danger)
            Text(message)
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer()
            Button("Dismiss") { workspace.dismissTransientError() }
                .controlSize(.small)
        }
        .padding(10)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(LeChatonTheme.danger.opacity(0.45)).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct CurrentAuthenticationControls: View {
    let workspace: WorkspaceController

    var body: some View {
        if let attempt = workspace.model.currentAuthenticationAttempt {
            VStack(alignment: .leading, spacing: 8) {
                Text("Finish sign-in in the browser, then verify it on the same Vibe authentication process.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Link("Open Sign-In Page", destination: attempt.signInURL)
                    Button("I Finished Signing In") {
                        Task {
                            await workspace.completeCurrentAuthentication(attemptID: attempt.id)
                        }
                    }
                    .disabled(isBusy)

                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                        Text(workspace.model.activity ?? "Checking authentication…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            HStack {
                Button("Refresh Status") {
                    Task { await workspace.refreshCurrentAuthentication() }
                }
                .disabled(isBusy)

                if isAuthenticated != true {
                    Button("Sign In…") {
                        Task { await workspace.startCurrentAuthentication() }
                    }
                    .disabled(isBusy)
                }

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                    Text(workspace.model.activity ?? "Checking authentication…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var isAuthenticated: Bool? {
        guard case let .status(status) = workspace.model.authentication else { return nil }
        return status.isAuthenticated
    }

    private var isBusy: Bool {
        workspace.model.lifecycle == .validatingExecutable
            || workspace.model.lifecycle == .swappingExecutable
    }
}

private struct ExecutableCandidateView: View {
    let workspace: WorkspaceController
    let candidate: ExecutableCandidatePresentation

    var body: some View {
        Section("Validated candidate") {
            LabeledContent("Path") {
                Text(candidate.executable.url.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            LabeledContent("Authentication", value: authenticationLabel(candidate.authentication))

            if let attempt = candidate.pendingSignIn {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Finish sign-in in the browser, then confirm below. The same private process completes the delegated flow.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Link("Open Sign-In Page", destination: attempt.signInURL)
                        Button("I Finished Signing In") {
                            Task {
                                await workspace.completeCandidateAuthentication(attemptID: attempt.id)
                            }
                        }
                        .disabled(isBusy)
                    }
                }
            } else if candidate.authentication.isAuthenticated != true {
                Button("Sign In…") {
                    Task { await workspace.startCandidateAuthentication() }
                }
                .disabled(isBusy)
            }

            HStack {
                Button("Discard") { Task { await workspace.discardExecutableCandidate() } }
                    .disabled(isBusy)
                Spacer()
                Button("Use This Executable") {
                    Task { await workspace.commitExecutableCandidate() }
                }
                .buttonStyle(.borderedProminent)
                .tint(LeChatonTheme.orange)
                .foregroundStyle(LeChatonTheme.onAccent)
                .disabled(candidate.authentication.isAuthenticated != true || isBusy)
            }

            if isBusy {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(workspace.model.activity ?? "Working with the validated executable…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var isBusy: Bool {
        workspace.model.lifecycle == .validatingExecutable
            || workspace.model.lifecycle == .swappingExecutable
    }
}

private struct ConfigurationOptionView: View {
    let option: VibeConfigurationOption
    let isApplying: Bool
    let onChange: (JSONValue) -> Void

    var body: some View {
        switch option.kind {
        case .select:
            Picker(
                option.name ?? option.id,
                selection: Binding(
                    get: { option.currentValue },
                    set: { newValue in onChange(newValue) }
                )
            ) {
                ForEach(Array(option.choices.enumerated()), id: \.offset) { _, choice in
                    Text(choice.name ?? displayValue(choice.value))
                        .tag(choice.value)
                }
            }
            .disabled(isApplying || option.choices.count <= 1)
            .help(option.choices.count <= 1 ? "Vibe advertised no alternative value" : "Changing this value reloads the session")
            .accessibilityHint(
                option.choices.count <= 1
                    ? "Vibe advertised no alternative value"
                    : "Changing this value reloads the session before it is published"
            )

        case .boolean:
            Toggle(
                option.name ?? option.id,
                isOn: Binding(
                    get: { option.currentValue.boolValue ?? false },
                    set: { onChange(.bool($0)) }
                )
            )
            .disabled(isApplying)

        case let .unknown(kind):
            LabeledContent(option.name ?? option.id, value: "Unsupported type: \(kind)")
                .foregroundStyle(.secondary)
        }
    }
}

private func authenticationLabel(_ status: VibeAuthenticationStatus) -> String {
    switch status.state {
    case .authenticated: "Authenticated"
    case .unauthenticated: "Sign-in required"
    case let .unknown(rawValue): rawValue.map { "Unknown (\($0))" } ?? "Unknown"
    }
}

private func displayValue(_ value: JSONValue) -> String {
    switch value {
    case let .string(string): string
    case let .bool(boolean): boolean ? "On" : "Off"
    case let .integer(integer): String(integer)
    case let .double(double): String(double)
    case .null: "None"
    case .array, .object: value.encodedString()
    }
}
