import Foundation
import LeChatonCore
import Observation

@MainActor
@Observable
final class ProviderSettingsController {
    enum Operation: Equatable {
        case testing
        case saving
        case activating
        case removing

        var label: String {
            switch self {
            case .testing: "Testing provider…"
            case .saving: "Saving provider…"
            case .activating: "Activating model…"
            case .removing: "Removing provider…"
            }
        }
    }

    private(set) var providers: [ManagedVibeProvider] = []
    private(set) var operation: Operation?
    private(set) var testResult: ProviderTestResult?
    private(set) var errorMessage: String?

    @ObservationIgnored private let store: ManagedVibeProviderStore
    @ObservationIgnored private let model: SessionModel
    @ObservationIgnored private let locateExecutable: @Sendable (String?) throws -> VibeExecutable
    @ObservationIgnored private var probeTask: Task<ProviderTestResult, any Error>?
    @ObservationIgnored private var probeOperationID: UUID?

    init(
        store: ManagedVibeProviderStore,
        model: SessionModel,
        locateExecutable: @escaping @Sendable (String?) throws -> VibeExecutable
    ) {
        self.store = store
        self.model = model
        self.locateExecutable = locateExecutable
    }

    var canActivate: Bool {
        !model.hasProvisionalThread && (model.lifecycle == .unloaded || model.lifecycle == .idle)
    }

    func reload() async {
        errorMessage = nil
        do {
            providers = try await store.reload()
            testResult = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func invalidateTest() {
        testResult = nil
    }

    func cancelTest() {
        guard operation == .testing else { return }
        probeTask?.cancel()
    }

    func test(_ draft: ProviderDraft) async {
        guard operation == nil else { return }
        errorMessage = nil
        testResult = nil
        operation = .testing
        let operationID = UUID()
        probeOperationID = operationID
        defer {
            if probeOperationID == operationID {
                resetProbeState()
            }
        }

        do {
            let executable = try locateExecutable(model.selectedVibePath)
            let task = Task { try await store.test(draft: draft, executable: executable) }
            probeTask = task
            let result = try await task.value
            if probeOperationID == operationID {
                testResult = result
            }
        } catch is CancellationError {
            // Shutdown owns cancellation and waits for the disposable process cleanup.
        } catch {
            if probeOperationID == operationID {
                errorMessage = String(describing: error)
            }
        }
    }

    func save(_ draft: ProviderDraft) async -> ManagedVibeProvider? {
        guard operation == nil, let testResult else {
            errorMessage = ManagedVibeProviderError.testRequired.description
            return nil
        }
        errorMessage = nil
        operation = .saving
        defer { operation = nil }
        do {
            let saved = try await store.save(draft: draft, testResultID: testResult.id)
            providers = try await store.providers()
            self.testResult = nil
            return saved
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    func activate(providerID: UUID, modelID: UUID) async {
        guard operation == nil, canActivate else { return }
        errorMessage = nil
        operation = .activating
        defer { operation = nil }
        do {
            try await model.activateProviderModel(providerID: providerID, modelID: modelID)
            providers = try await store.providers()
        } catch {
            errorMessage = String(describing: error)
            await reloadAfterFailure()
        }
    }

    func remove(providerID: UUID) async {
        guard operation == nil else { return }
        errorMessage = nil
        operation = .removing
        defer { operation = nil }
        do {
            try await store.remove(providerID: providerID)
            providers = try await store.providers()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func shutdown() async {
        let task = probeTask
        task?.cancel()
        _ = await task?.result
        resetProbeState()
    }

    private func reloadAfterFailure() async {
        do {
            providers = try await store.reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func resetProbeState() {
        probeTask = nil
        probeOperationID = nil
        operation = nil
    }
}
