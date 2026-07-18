import Foundation

public struct VibeAuthenticationSnapshot: Equatable, Sendable {
    public let compatibility: VibeCompatibility
    public let status: VibeAuthenticationStatus
}

public enum AuthCoordinatorError: Error, Equatable, Sendable, CustomStringConvertible {
    case disposing
    case runtimeInvalidated
    case delegatedAuthenticationUnavailable
    case authenticationOperationInProgress
    case attemptAlreadyPending(String)
    case noPendingAttempt
    case attemptMismatch(expected: String, received: String)

    public var description: String {
        switch self {
        case .disposing: "The authentication process is being disposed"
        case .runtimeInvalidated: "The authentication process was invalidated while starting"
        case .delegatedAuthenticationUnavailable:
            "Vibe did not advertise delegated browser authentication"
        case .authenticationOperationInProgress:
            "A delegated authentication operation is already in progress"
        case let .attemptAlreadyPending(attemptID):
            "Delegated authentication attempt \(attemptID) is already pending"
        case .noPendingAttempt: "No delegated authentication attempt is pending"
        case let .attemptMismatch(expected, received):
            "Expected delegated authentication attempt \(expected), received \(received)"
        }
    }
}

/// Owns one lazy, project-independent authentication process.
public actor AuthCoordinator {
    private struct OwnedRuntime: Sendable {
        let id: UUID
        let validated: VibeValidatedTransport
    }

    private struct CleanupOutcome: Sendable {
        let runtime: OwnedRuntime?
        let report: ProcessCleanupReport?
    }

    private enum RuntimeState {
        case unloaded
        case starting(id: UUID, task: Task<OwnedRuntime, any Error>)
        case loaded(OwnedRuntime)
        case disposing(Task<CleanupOutcome, Never>)
        case cleanupRequired(runtime: OwnedRuntime, report: ProcessCleanupReport)
    }

    private enum DelegatedAuthenticationState {
        case idle
        case starting
        case pending(VibeDelegatedAuthenticationAttempt)
        case completing(VibeDelegatedAuthenticationAttempt)
    }

    public let executable: VibeExecutable
    public let neutralWorkingDirectory: URL

    private let adapter: VibeAdapter
    private let processOptions: VibeProcessOptions
    private var runtimeState: RuntimeState = .unloaded
    private var delegatedAuthenticationState: DelegatedAuthenticationState = .idle

    public init(
        adapter: VibeAdapter = VibeAdapter(),
        executable: VibeExecutable,
        neutralWorkingDirectory: URL
    ) {
        self.adapter = adapter
        self.executable = executable
        self.neutralWorkingDirectory = neutralWorkingDirectory
        processOptions = .init()
    }

    init(
        adapter: VibeAdapter = VibeAdapter(),
        executable: VibeExecutable,
        neutralWorkingDirectory: URL,
        processOptions: VibeProcessOptions
    ) {
        self.adapter = adapter
        self.executable = executable
        self.neutralWorkingDirectory = neutralWorkingDirectory
        self.processOptions = processOptions
    }

    /// Launches lazily and returns exact compatibility plus the authoritative Vibe auth status.
    public func refresh() async throws -> VibeAuthenticationSnapshot {
        let runtime = try await ensureRuntime()
        let status = try await adapter.authenticationStatus(transport: runtime.validated.transport)
        return .init(compatibility: runtime.validated.compatibility, status: status)
    }

    public func authenticationStatus() async throws -> VibeAuthenticationStatus {
        try await refresh().status
    }

    public func compatibility() async throws -> VibeCompatibility {
        try await ensureRuntime().validated.compatibility
    }

    /// The pending attempt is actor-owned and can only be completed on this same runtime.
    public func startDelegatedAuthentication() async throws -> VibeDelegatedAuthenticationAttempt {
        switch delegatedAuthenticationState {
        case .idle:
            delegatedAuthenticationState = .starting
        case .starting:
            throw AuthCoordinatorError.authenticationOperationInProgress
        case let .pending(attempt), let .completing(attempt):
            throw AuthCoordinatorError.attemptAlreadyPending(attempt.id)
        }

        do {
            let runtime = try await ensureRuntime()
            guard Self.supportsDelegatedAuthentication(runtime.validated.compatibility.initialization) else {
                throw AuthCoordinatorError.delegatedAuthenticationUnavailable
            }
            let attempt = try await adapter.startDelegatedAuthentication(
                transport: runtime.validated.transport
            )
            guard try currentLoadedRuntimeID() == runtime.id else {
                throw AuthCoordinatorError.runtimeInvalidated
            }
            delegatedAuthenticationState = .pending(attempt)
            return attempt
        } catch {
            if case .starting = delegatedAuthenticationState {
                delegatedAuthenticationState = .idle
            }
            if let adapterError = error as? VibeAdapterError,
               adapterError == .invalidDelegatedAuthenticationStart
            {
                // Do not leave an unidentifiable process-bound attempt behind.
                _ = try? await dispose()
            }
            throw error
        }
    }

    /// A failed completion remains retryable on the same owner. A successful wire completion
    /// clears the transient attempt before querying authoritative status.
    public func completeDelegatedAuthentication(
        attemptID: String
    ) async throws -> VibeAuthenticationStatus {
        let pendingAttempt: VibeDelegatedAuthenticationAttempt
        switch delegatedAuthenticationState {
        case .idle:
            throw AuthCoordinatorError.noPendingAttempt
        case .starting, .completing:
            throw AuthCoordinatorError.authenticationOperationInProgress
        case let .pending(attempt):
            pendingAttempt = attempt
        }
        guard pendingAttempt.id == attemptID else {
            throw AuthCoordinatorError.attemptMismatch(
                expected: pendingAttempt.id,
                received: attemptID
            )
        }
        delegatedAuthenticationState = .completing(pendingAttempt)
        do {
            let runtime = try await ensureRuntime()
            _ = try await adapter.completeDelegatedAuthentication(
                attemptID: attemptID,
                transport: runtime.validated.transport
            )
            guard try currentLoadedRuntimeID() == runtime.id else {
                throw AuthCoordinatorError.runtimeInvalidated
            }
            delegatedAuthenticationState = .idle
            return try await adapter.authenticationStatus(transport: runtime.validated.transport)
        } catch {
            if case let .completing(attempt) = delegatedAuthenticationState,
               attempt.id == pendingAttempt.id
            {
                // Vibe may keep retryable completion attempts in this same live process.
                delegatedAuthenticationState = .pending(pendingAttempt)
            }
            throw error
        }
    }

    public func pendingDelegatedAuthentication() -> VibeDelegatedAuthenticationAttempt? {
        switch delegatedAuthenticationState {
        case let .pending(attempt), let .completing(attempt): attempt
        case .idle, .starting: nil
        }
    }

    /// Idempotently stops the auth owner and verifies that its complete process tree is gone.
    @discardableResult
    public func dispose() async throws -> ProcessCleanupReport? {
        delegatedAuthenticationState = .idle
        let cleanup: Task<CleanupOutcome, Never>
        switch runtimeState {
        case .unloaded:
            return nil
        case .cleanupRequired:
            return try await retryCleanup()
        case let .disposing(existing):
            cleanup = existing
        case let .loaded(runtime):
            cleanup = Task {
                CleanupOutcome(
                    runtime: runtime,
                    report: await runtime.validated.transport.stop()
                )
            }
            runtimeState = .disposing(cleanup)
        case let .starting(_, startTask):
            startTask.cancel()
            cleanup = Task {
                guard case let .success(runtime) = await startTask.result else {
                    return CleanupOutcome(runtime: nil, report: nil)
                }
                return CleanupOutcome(
                    runtime: runtime,
                    report: await runtime.validated.transport.stop()
                )
            }
            runtimeState = .disposing(cleanup)
        }

        let outcome = await cleanup.value
        if let report = outcome.report, !report.survivors.isEmpty,
           let runtime = outcome.runtime
        {
            runtimeState = .cleanupRequired(runtime: runtime, report: report)
            throw ACPTransportError.cleanupFailed(report.survivors)
        }
        runtimeState = .unloaded
        return outcome.report
    }

    /// Retries verified descendant cleanup without allowing the failed owner to be reused or
    /// published. The transport remains retained until every tracked identity is gone.
    @discardableResult
    public func retryCleanup() async throws -> ProcessCleanupReport? {
        guard case let .cleanupRequired(runtime, previousReport) = runtimeState else {
            return try await dispose()
        }
        do {
            let report = try await runtime.validated.transport.forceCleanup()
            guard report.survivors.isEmpty else {
                runtimeState = .cleanupRequired(runtime: runtime, report: report)
                throw ACPTransportError.cleanupFailed(report.survivors)
            }
            runtimeState = .unloaded
            return report
        } catch {
            runtimeState = .cleanupRequired(runtime: runtime, report: previousReport)
            throw error
        }
    }

    func rootProcessIdentity() async -> ProcessIdentity? {
        switch runtimeState {
        case let .loaded(runtime):
            await runtime.validated.transport.rootProcessIdentity()
        case let .cleanupRequired(runtime, _):
            await runtime.validated.transport.rootProcessIdentity()
        default:
            nil
        }
    }

    private func ensureRuntime() async throws -> OwnedRuntime {
        switch runtimeState {
        case let .loaded(runtime):
            return runtime
        case .disposing, .cleanupRequired:
            throw AuthCoordinatorError.disposing
        case let .starting(id, task):
            return try await resolveStart(id: id, task: task)
        case .unloaded:
            let id = UUID()
            let adapter = adapter
            let executable = executable
            let neutralWorkingDirectory = neutralWorkingDirectory
            let processOptions = processOptions
            let task = Task<OwnedRuntime, any Error> {
                let validated = try await adapter.launchValidatedAuthenticationProcess(
                    executable: executable,
                    workingDirectory: neutralWorkingDirectory,
                    processOptions: processOptions
                )
                return OwnedRuntime(id: id, validated: validated)
            }
            runtimeState = .starting(id: id, task: task)
            return try await resolveStart(id: id, task: task)
        }
    }

    private func resolveStart(
        id: UUID,
        task: Task<OwnedRuntime, any Error>
    ) async throws -> OwnedRuntime {
        do {
            let runtime = try await task.value
            switch runtimeState {
            case let .starting(currentID, _) where currentID == id:
                runtimeState = .loaded(runtime)
                return runtime
            case let .loaded(current) where current.id == id:
                return current
            default:
                _ = await runtime.validated.transport.stop()
                throw AuthCoordinatorError.runtimeInvalidated
            }
        } catch {
            if case let .starting(currentID, _) = runtimeState, currentID == id {
                runtimeState = .unloaded
            }
            throw error
        }
    }

    private func currentLoadedRuntimeID() throws -> UUID {
        guard case let .loaded(runtime) = runtimeState else {
            throw AuthCoordinatorError.runtimeInvalidated
        }
        return runtime.id
    }

    private static func supportsDelegatedAuthentication(_ initialization: ACPInitializeResult) -> Bool {
        initialization.authenticationMethods.contains { rawMethod in
            rawMethod["id"]?.stringValue == VibeAdapter.delegatedAuthenticationMethodID
        }
    }
}

/// Candidate owners are internal and cannot be published as application auth state. The swap
/// coordinator must either dispose one or explicitly take its validated owner at the commit edge.
actor VibeAuthenticationCandidate {
    private var coordinator: AuthCoordinator?

    init(coordinator: AuthCoordinator) {
        self.coordinator = coordinator
    }

    func refresh() async throws -> VibeAuthenticationSnapshot {
        guard let coordinator else { throw AuthCoordinatorError.runtimeInvalidated }
        return try await coordinator.refresh()
    }

    func startDelegatedAuthentication() async throws -> VibeDelegatedAuthenticationAttempt {
        guard let coordinator else { throw AuthCoordinatorError.runtimeInvalidated }
        return try await coordinator.startDelegatedAuthentication()
    }

    func completeDelegatedAuthentication(attemptID: String) async throws -> VibeAuthenticationStatus {
        guard let coordinator else { throw AuthCoordinatorError.runtimeInvalidated }
        return try await coordinator.completeDelegatedAuthentication(attemptID: attemptID)
    }

    @discardableResult
    func dispose() async throws -> ProcessCleanupReport? {
        guard let coordinator else { return nil }
        let report = try await coordinator.dispose()
        self.coordinator = nil
        return report
    }

    @discardableResult
    func retryCleanup() async throws -> ProcessCleanupReport? {
        guard let coordinator else { return nil }
        let report = try await coordinator.retryCleanup()
        self.coordinator = nil
        return report
    }

    /// Re-queries immediately before transferring the owner out of candidate state.
    func takeValidatedOwner() async throws -> (AuthCoordinator, VibeAuthenticationSnapshot) {
        guard let coordinator else { throw AuthCoordinatorError.runtimeInvalidated }
        let snapshot = try await coordinator.refresh()
        guard self.coordinator === coordinator else {
            throw AuthCoordinatorError.runtimeInvalidated
        }
        self.coordinator = nil
        return (coordinator, snapshot)
    }

    func rootProcessIdentity() async -> ProcessIdentity? {
        await coordinator?.rootProcessIdentity()
    }
}

extension VibeAdapter {
    func makeAuthenticationCandidate(
        executable: VibeExecutable,
        neutralWorkingDirectory: URL,
        processOptions: VibeProcessOptions = .init()
    ) -> VibeAuthenticationCandidate {
        VibeAuthenticationCandidate(coordinator: AuthCoordinator(
            adapter: self,
            executable: executable,
            neutralWorkingDirectory: neutralWorkingDirectory,
            processOptions: processOptions
        ))
    }
}
