import LeChatonCore
import SwiftUI

struct SettingsRootView: View {
    let container: ApplicationContainer

    var body: some View {
        Group {
            switch container.startupState {
            case .starting:
                ProgressView("Opening local metadata…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(failure):
                ContentUnavailableView(
                    failure.title,
                    systemImage: "exclamationmark.triangle",
                    description: Text("Resolve this issue in the LeChaton workspace window.")
                )
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

    var body: some View {
        TabView {
            executableSettings
                .tabItem { Label("Vibe", systemImage: "terminal") }

            configurationSettings
                .tabItem { Label("Model", systemImage: "slider.horizontal.3") }
        }
        .scenePadding()
        .tint(LeChatonTheme.orange)
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
            }

            if let candidate = workspace.model.executableCandidate {
                ExecutableCandidateView(workspace: workspace, candidate: candidate)
            }
        }
        .formStyle(.grouped)
    }

    private var configurationSettings: some View {
        Form {
            Section("Model and thinking") {
                if workspace.model.lifecycle != .idle {
                    ContentUnavailableView(
                        "Load an idle Thread",
                        systemImage: "pause.circle",
                        description: Text("Resume the saved Thread before changing Vibe configuration.")
                    )
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
                }
            }

            if case let .reloadRequired(optionID, requestedValue) = workspace.model.configurationState {
                Section("Reload required") {
                    Label(
                        "Vibe may have retained \(optionID) = \(displayValue(requestedValue)). Resume in the workspace to re-query the effective value.",
                        systemImage: "arrow.clockwise.circle"
                    )
                    .foregroundStyle(.orange)
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
        workspace.model.lifecycle == .unloaded || workspace.model.lifecycle == .idle
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
                    }
                }
            } else if candidate.authentication.isAuthenticated != true {
                Button("Sign In…") {
                    Task { await workspace.startCandidateAuthentication() }
                }
            }

            HStack {
                Button("Discard") { Task { await workspace.discardExecutableCandidate() } }
                Spacer()
                Button("Use This Executable") {
                    Task { await workspace.commitExecutableCandidate() }
                }
                .buttonStyle(.borderedProminent)
                .tint(LeChatonTheme.orange)
                .foregroundStyle(LeChatonTheme.onAccent)
                .disabled(candidate.authentication.isAuthenticated != true)
            }
        }
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
