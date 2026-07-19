import Foundation
import LeChatonCore
import Observation

@MainActor
@Observable
final class GitInspectionController {
    private(set) var baseline: GitStatusSnapshot?
    private(set) var inspection: GitInspection?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let inspector: GitInspector
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var operations: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var acceptsOperations = true

    init(inspector: GitInspector) {
        self.inspector = inspector
    }

    @discardableResult
    func captureBaseline(repository: URL) async -> Bool {
        guard let operationID = beginOperation(clearInspection: true) else { return false }
        let inspector = self.inspector
        let operation = Task { @MainActor [weak self] in
            let outcome: GitOperationOutcome<GitStatusSnapshot>
            do {
                try Task.checkCancellation()
                let baseline = try await inspector.captureBaseline(repository: repository)
                try Task.checkCancellation()
                outcome = .success(baseline)
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .failure(String(describing: error))
            }
            self?.completeBaseline(operationID: operationID, outcome: outcome)
        }
        operations[operationID] = operation
        await operation.value

        guard acceptsOperations, self.operationID == operationID else { return false }
        return baseline != nil
    }

    @discardableResult
    func refresh(repository: URL) async -> Bool {
        guard let operationID = beginOperation(clearInspection: false) else { return false }
        let inspector = self.inspector
        let existingBaseline = baseline
        let operation = Task { @MainActor [weak self] in
            let outcome: GitOperationOutcome<(GitStatusSnapshot, GitInspection)>
            do {
                try Task.checkCancellation()
                var baseline: GitStatusSnapshot
                if let existingBaseline {
                    baseline = existingBaseline
                } else {
                    baseline = try await inspector.captureBaseline(repository: repository)
                }
                try Task.checkCancellation()
                let inspection: GitInspection
                do {
                    inspection = try await inspector.inspect(repository: repository, baseline: baseline)
                } catch let error as GitInspectionError {
                    guard case .repositoryRootMismatch = error else { throw error }
                    try Task.checkCancellation()
                    baseline = try await inspector.captureBaseline(repository: repository)
                    try Task.checkCancellation()
                    inspection = try await inspector.inspect(repository: repository, baseline: baseline)
                }
                try Task.checkCancellation()
                outcome = .success((baseline, inspection))
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .failure(String(describing: error))
            }
            self?.completeInspection(operationID: operationID, outcome: outcome)
        }
        operations[operationID] = operation
        await operation.value

        guard acceptsOperations, self.operationID == operationID else { return false }
        return baseline != nil
    }

    func clear() {
        cancelOperations()
        baseline = nil
        inspection = nil
        errorMessage = nil
        isLoading = false
    }

    /// Prevents new Git work, cancels every task owned by this controller, and
    /// waits for each task to finish before application termination can proceed.
    func prepareForShutdown() async {
        acceptsOperations = false
        cancelOperations()
        baseline = nil
        inspection = nil
        errorMessage = nil
        isLoading = false

        let pending = Array(operations.values)
        for operation in pending {
            await operation.value
        }
    }

    /// Application termination can be rejected when runtime cleanup fails. In
    /// that case the existing controller remains valid for subsequent recovery.
    func resumeAfterFailedShutdown() {
        acceptsOperations = true
    }

    private func beginOperation(clearInspection: Bool) -> UUID? {
        guard acceptsOperations else { return nil }
        cancelOperations()
        let operationID = UUID()
        self.operationID = operationID
        isLoading = true
        errorMessage = nil
        if clearInspection { inspection = nil }
        return operationID
    }

    private func cancelOperations() {
        operationID = UUID()
        for operation in operations.values {
            operation.cancel()
        }
    }

    private func completeBaseline(
        operationID: UUID,
        outcome: GitOperationOutcome<GitStatusSnapshot>
    ) {
        operations.removeValue(forKey: operationID)
        guard acceptsOperations, self.operationID == operationID else { return }
        isLoading = false
        switch outcome {
        case let .success(baseline):
            self.baseline = baseline
            errorMessage = nil
        case let .failure(message):
            baseline = nil
            errorMessage = message
        case .cancelled:
            errorMessage = nil
        }
    }

    private func completeInspection(
        operationID: UUID,
        outcome: GitOperationOutcome<(GitStatusSnapshot, GitInspection)>
    ) {
        operations.removeValue(forKey: operationID)
        guard acceptsOperations, self.operationID == operationID else { return }
        isLoading = false
        switch outcome {
        case let .success((baseline, inspection)):
            self.baseline = baseline
            self.inspection = inspection
            errorMessage = nil
        case let .failure(message):
            inspection = nil
            errorMessage = message
        case .cancelled:
            errorMessage = nil
        }
    }
}

private enum GitOperationOutcome<Value: Sendable>: Sendable {
    case success(Value)
    case failure(String)
    case cancelled
}
