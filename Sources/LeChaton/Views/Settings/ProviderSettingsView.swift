import LeChatonCore
import SwiftUI

struct ProviderSettingsView: View {
    let workspace: WorkspaceController

    @State private var selection: UUID?
    @State private var editingDraft: ProviderDraft?
    @State private var activation: ProviderActivation?
    @State private var removal: ManagedVibeProvider?

    private var controller: ProviderSettingsController { workspace.providers }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                providerList
                    .frame(minWidth: 210, idealWidth: 230, maxWidth: 280)
                providerDetail
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }

            if let error = controller.errorMessage {
                providerError(error)
            }
        }
        .sheet(item: $editingDraft) { draft in
            ProviderEditorView(
                initialDraft: draft,
                controller: controller,
                onSaved: { provider in
                    selection = provider.id
                    editingDraft = nil
                },
                onCancel: { editingDraft = nil }
            )
        }
        .confirmationDialog(
            "Activate this model?",
            isPresented: Binding(
                get: { activation != nil },
                set: { if !$0 { activation = nil } }
            ),
            presenting: activation
        ) { selection in
            Button("Activate \(selection.modelName)") {
                Task {
                    await controller.activate(
                        providerID: selection.providerID,
                        modelID: selection.modelID
                    )
                    activation = nil
                }
            }
            Button("Cancel", role: .cancel) { activation = nil }
        } message: { _ in
            Text("LeChaton will stop the current Vibe owners, update Vibe's active model, and leave the Thread Unloaded. Resume explicitly when ready.")
        }
        .confirmationDialog(
            "Remove this provider?",
            isPresented: Binding(
                get: { removal != nil },
                set: { if !$0 { removal = nil } }
            ),
            presenting: removal
        ) { provider in
            Button("Remove \(provider.name)", role: .destructive) {
                Task {
                    await controller.remove(providerID: provider.id)
                    if selection == provider.id { selection = nil }
                    removal = nil
                }
            }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: { _ in
            Text("This removes only LeChaton-managed Vibe entries and their Keychain credential.")
        }
        .onAppear(perform: repairSelection)
        .onChange(of: controller.providers) {
            repairSelection()
        }
    }

    private var providerList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Providers")
                    .font(.headline)
                Spacer()
                Button {
                    editingDraft = ProviderDraft()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add Provider")
                .disabled(controller.operation != nil)
            }
            .padding(12)

            Divider()

            if controller.providers.isEmpty {
                ContentUnavailableView(
                    "No providers",
                    systemImage: "server.rack",
                    description: Text("Add an OpenAI-compatible endpoint.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(controller.providers, selection: $selection) { provider in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(provider.name)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Spacer()
                            if provider.status == .active {
                                Text("ACTIVE")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(LeChatonTheme.success)
                            }
                        }
                        Text(provider.baseURL.host() ?? provider.baseURL.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .tag(provider.id)
                }
                .listStyle(.sidebar)
            }

            Divider()
            HStack {
                Button("Reload") { Task { await controller.reload() } }
                    .disabled(controller.operation != nil)
                Spacer()
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private var providerDetail: some View {
        if let provider = selectedProvider {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(provider.name)
                                .font(.title2.weight(.semibold))
                            Text(provider.baseURL.absoluteString)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button("Edit") { editingDraft = ProviderDraft(provider: provider) }
                            .disabled(controller.operation != nil)
                    }

                    LabeledContent("Authentication") {
                        Text(provider.authMode == .bearer ? "Bearer API key" : "Keyless loopback")
                    }

                    Divider()

                    Text("Models")
                        .font(.headline)
                    ForEach(provider.models) { model in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.displayName)
                                    .fontWeight(.medium)
                                Text(model.modelID)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if provider.activeModelID == model.id {
                                Text("Active")
                                    .font(.caption)
                                    .foregroundStyle(LeChatonTheme.success)
                            }
                            Button("Activate") {
                                activation = .init(
                                    providerID: provider.id,
                                    modelID: model.id,
                                    modelName: model.displayName
                                )
                            }
                            .disabled(
                                provider.activeModelID == model.id
                                    || !controller.canActivate
                                    || controller.operation != nil
                            )
                        }
                        .padding(12)
                        .background(.regularMaterial, in: .rect(cornerRadius: 10))
                    }

                    Divider()

                    HStack {
                        if let operation = controller.operation {
                            ProgressView()
                                .controlSize(.small)
                            Text(operation.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove Provider", role: .destructive) {
                            removal = provider
                        }
                        .disabled(provider.status == .active || controller.operation != nil)
                        .help(provider.status == .active ? "Activate a model from another provider first" : "")
                    }
                }
                .padding(20)
            }
        } else {
            ContentUnavailableView(
                "Select a provider",
                systemImage: "server.rack",
                description: Text("Provider profiles are applied through Vibe and never bypass ACP.")
            )
        }
    }

    private var selectedProvider: ManagedVibeProvider? {
        controller.providers.first { $0.id == selection }
    }

    private func providerError(_ message: String) -> some View {
        HStack(spacing: 10) {
            Label("Provider action failed", systemImage: "xmark.circle")
                .font(.callout.weight(.semibold))
                .foregroundStyle(LeChatonTheme.danger)
            Text(message)
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer()
            Button("Dismiss") { controller.dismissError() }
                .controlSize(.small)
        }
        .padding(10)
        .background(.regularMaterial)
    }

    private func repairSelection() {
        guard !controller.providers.contains(where: { $0.id == selection }) else { return }
        selection = controller.providers.first?.id
    }
}

private struct ProviderActivation: Identifiable {
    let providerID: UUID
    let modelID: UUID
    let modelName: String
    var id: String { "\(providerID.uuidString)-\(modelID.uuidString)" }
}

private struct ProviderEditorView: View {
    @State private var draft: ProviderDraft
    let controller: ProviderSettingsController
    let onSaved: (ManagedVibeProvider) -> Void
    let onCancel: () -> Void

    init(
        initialDraft: ProviderDraft,
        controller: ProviderSettingsController,
        onSaved: @escaping (ManagedVibeProvider) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: initialDraft)
        self.controller = controller
        self.onSaved = onSaved
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Provider") {
                    TextField("Name", text: $draft.name)
                    TextField("Base URL", text: $draft.baseURL)
                        .textContentType(.URL)
                    Picker("Authentication", selection: $draft.authMode) {
                        Text("Bearer API key").tag(ProviderAuthMode.bearer)
                        Text("Keyless loopback").tag(ProviderAuthMode.keylessLoopback)
                    }

                    if draft.authMode == .bearer {
                        SecureField("API key", text: $draft.apiKey)
                        Text("Leave blank while editing to retain the existing Keychain value.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Keyless mode is accepted only for localhost, 127.0.0.1, or ::1.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Models") {
                    ForEach($draft.models) { $model in
                        HStack {
                            VStack(alignment: .leading) {
                                TextField("Model ID", text: $model.modelID)
                                TextField("Display name", text: $model.displayName)
                            }
                            Button(role: .destructive) {
                                draft.models.removeAll { $0.id == model.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .disabled(draft.models.count == 1)
                        }
                    }
                    Button("Add Model", systemImage: "plus") {
                        draft.models.append(.init(modelID: "", displayName: ""))
                    }
                }

                Section("Provider test") {
                    Text("Testing sends a small token-consuming prompt through a disposable Vibe ACP process and performs one safe file-tool check in a temporary Git repository.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if controller.testResult?.providerID == draft.id {
                        Label("This exact draft passed", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(LeChatonTheme.success)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(controller.operation != nil)
                Spacer()
                if controller.operation != nil {
                    ProgressView()
                        .controlSize(.small)
                }
                if controller.operation == .testing {
                    Button("Cancel Test") {
                        controller.cancelTest()
                    }
                } else {
                    Button("Test Provider") {
                        Task { await controller.test(draft) }
                    }
                    .disabled(controller.operation != nil)
                }
                Button("Save") {
                    Task {
                        if let provider = await controller.save(draft) {
                            onSaved(provider)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(controller.testResult?.providerID != draft.id || controller.operation != nil)
            }
            .padding(14)
        }
        .frame(width: 600, height: 560)
        .interactiveDismissDisabled(controller.operation != nil)
        .onChange(of: draft) {
            controller.invalidateTest()
        }
    }
}
