import Foundation

public struct SessionRuntimeStart: Equatable, Sendable {
    public let generation: UUID
    public let compatibility: VibeCompatibility

    public init(generation: UUID, compatibility: VibeCompatibility) {
        self.generation = generation
        self.compatibility = compatibility
    }
}

/// SessionModel talks to one runtime through this boundary. The live implementation owns one
/// ACPTransport; tests substitute an actor without launching a process.
public protocol SessionRuntime: Actor {
    func start() async throws -> SessionRuntimeStart
    func updates() async -> AsyncStream<EventEnvelope<SessionUpdate>>
    func incomingRequests() async -> AsyncStream<IncomingACPRequest>
    func diagnostics() async -> AsyncStream<ACPDiagnostic>
    func failure() async -> ACPTransportError?
    func repositoryTrustStatus(cwd: URL) async throws -> VibeRepositoryTrustStatus
    func applyRepositoryTrustDecision(cwd: URL, decision: String) async throws -> VibeRepositoryTrustStatus
    func newSession(cwd: URL) async throws -> NewSessionResult
    func loadSession(sessionID: String, cwd: URL) async throws -> LoadSessionResult
    func prompt(sessionID: String, text: String) async throws -> PromptResult
    func setConfigurationOption(
        sessionID: String,
        optionID: String,
        kind: VibeConfigurationOption.Kind,
        value: JSONValue
    ) async throws -> VibeConfigurationWriteResult
    func respondToPermission(id: RPCID, selectedOptionID: String) async throws
    func respondToPermissionCancellation(id: RPCID) async throws
    func cancelPrompt(sessionID: String) async throws -> Bool
    func stop() async -> ProcessCleanupReport?
    func retryCleanup() async throws -> ProcessCleanupReport?
}

actor LiveSessionRuntime: SessionRuntime {
    private let executable: VibeExecutable
    private let workingDirectory: URL
    private let adapter: VibeAdapter
    private let transport: ACPTransport

    init(executable: VibeExecutable, workingDirectory: URL, adapter: VibeAdapter) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.adapter = adapter
        transport = ACPTransport(configuration: .init(
            executableURL: executable.url,
            workingDirectory: workingDirectory
        ))
    }

    func start() async throws -> SessionRuntimeStart {
        do {
            let generation = try await transport.start()
            let compatibility = try await adapter.initializeAndValidate(
                transport: transport,
                executable: executable
            )
            return .init(generation: generation, compatibility: compatibility)
        } catch {
            _ = await transport.stop()
            throw error
        }
    }

    func updates() async -> AsyncStream<EventEnvelope<SessionUpdate>> {
        await transport.updates()
    }

    func incomingRequests() async -> AsyncStream<IncomingACPRequest> {
        await transport.incomingRequests()
    }

    func diagnostics() async -> AsyncStream<ACPDiagnostic> {
        await transport.diagnostics()
    }

    func failure() async -> ACPTransportError? {
        await transport.failure()
    }

    func repositoryTrustStatus(cwd: URL) async throws -> VibeRepositoryTrustStatus {
        try await adapter.repositoryTrustStatus(cwd: cwd, transport: transport)
    }

    func applyRepositoryTrustDecision(
        cwd: URL,
        decision: String
    ) async throws -> VibeRepositoryTrustStatus {
        try await adapter.applyRepositoryTrustDecision(
            cwd: cwd,
            decision: decision,
            transport: transport
        )
    }

    func newSession(cwd: URL) async throws -> NewSessionResult {
        try await transport.newSession(cwd: cwd)
    }

    func loadSession(sessionID: String, cwd: URL) async throws -> LoadSessionResult {
        try await transport.loadSession(sessionID: sessionID, cwd: cwd)
    }

    func prompt(sessionID: String, text: String) async throws -> PromptResult {
        try await transport.prompt(sessionID: sessionID, text: text)
    }

    func setConfigurationOption(
        sessionID: String,
        optionID: String,
        kind: VibeConfigurationOption.Kind,
        value: JSONValue
    ) async throws -> VibeConfigurationWriteResult {
        try await adapter.setConfigurationOption(
            sessionID: sessionID,
            optionID: optionID,
            kind: kind,
            value: value,
            transport: transport
        )
    }

    func respondToPermission(id: RPCID, selectedOptionID: String) async throws {
        try await transport.respondToPermission(id: id, selectedOptionID: selectedOptionID)
    }

    func respondToPermissionCancellation(id: RPCID) async throws {
        try await transport.respondToPermissionCancellation(id: id)
    }

    func cancelPrompt(sessionID: String) async throws -> Bool {
        try await transport.cancelPrompt(sessionID: sessionID)
    }

    func stop() async -> ProcessCleanupReport? {
        await transport.stop()
    }

    func retryCleanup() async throws -> ProcessCleanupReport? {
        try await transport.forceCleanup()
    }
}

public protocol SessionAuthenticationOwner: Actor {
    func refresh() async throws -> VibeAuthenticationSnapshot
    func startDelegatedAuthentication() async throws -> VibeDelegatedAuthenticationAttempt
    func completeDelegatedAuthentication(attemptID: String) async throws -> VibeAuthenticationStatus
    func pendingDelegatedAuthentication() -> VibeDelegatedAuthenticationAttempt?
    func dispose() async throws -> ProcessCleanupReport?
    func retryCleanup() async throws -> ProcessCleanupReport?
}

extension AuthCoordinator: SessionAuthenticationOwner {}

public struct SessionAuthenticationPromotion: Sendable {
    public let owner: any SessionAuthenticationOwner
    public let snapshot: VibeAuthenticationSnapshot

    public init(owner: any SessionAuthenticationOwner, snapshot: VibeAuthenticationSnapshot) {
        self.owner = owner
        self.snapshot = snapshot
    }
}

public protocol SessionAuthenticationCandidate: Actor {
    func refresh() async throws -> VibeAuthenticationSnapshot
    func startDelegatedAuthentication() async throws -> VibeDelegatedAuthenticationAttempt
    func completeDelegatedAuthentication(attemptID: String) async throws -> VibeAuthenticationStatus
    func promote() async throws -> SessionAuthenticationPromotion
    func dispose() async throws -> ProcessCleanupReport?
    func retryCleanup() async throws -> ProcessCleanupReport?
}

actor LiveSessionAuthenticationCandidate: SessionAuthenticationCandidate {
    private let candidate: VibeAuthenticationCandidate

    init(candidate: VibeAuthenticationCandidate) {
        self.candidate = candidate
    }

    func refresh() async throws -> VibeAuthenticationSnapshot {
        try await candidate.refresh()
    }

    func startDelegatedAuthentication() async throws -> VibeDelegatedAuthenticationAttempt {
        try await candidate.startDelegatedAuthentication()
    }

    func completeDelegatedAuthentication(attemptID: String) async throws -> VibeAuthenticationStatus {
        try await candidate.completeDelegatedAuthentication(attemptID: attemptID)
    }

    func promote() async throws -> SessionAuthenticationPromotion {
        let (owner, snapshot) = try await candidate.takeValidatedOwner()
        return .init(owner: owner, snapshot: snapshot)
    }

    func dispose() async throws -> ProcessCleanupReport? {
        try await candidate.dispose()
    }

    func retryCleanup() async throws -> ProcessCleanupReport? {
        try await candidate.retryCleanup()
    }
}

public struct SessionPersistenceClient: Sendable {
    public var restoreMetadata: @Sendable () async throws -> PersistenceSnapshot
    public var createThread: @Sendable (CreateThreadRequest) async throws -> SavedThreadMetadata
    public var replaceSelectedThread: @Sendable (UUID, CreateThreadRequest) async throws -> SavedThreadMetadata
    public var removeSelectedThread: @Sendable (UUID) async throws -> SavedThreadMetadata
    public var updateSelectedVibePath: @Sendable (URL?) async throws -> AppSettingsMetadata
    public var resetLocalMetadata: @Sendable () async throws -> PersistenceResetResult
    public var close: @Sendable () async throws -> Void

    public init(
        restoreMetadata: @escaping @Sendable () async throws -> PersistenceSnapshot,
        createThread: @escaping @Sendable (CreateThreadRequest) async throws -> SavedThreadMetadata,
        replaceSelectedThread: @escaping @Sendable (UUID, CreateThreadRequest) async throws -> SavedThreadMetadata,
        removeSelectedThread: @escaping @Sendable (UUID) async throws -> SavedThreadMetadata,
        updateSelectedVibePath: @escaping @Sendable (URL?) async throws -> AppSettingsMetadata,
        resetLocalMetadata: @escaping @Sendable () async throws -> PersistenceResetResult,
        close: @escaping @Sendable () async throws -> Void
    ) {
        self.restoreMetadata = restoreMetadata
        self.createThread = createThread
        self.replaceSelectedThread = replaceSelectedThread
        self.removeSelectedThread = removeSelectedThread
        self.updateSelectedVibePath = updateSelectedVibePath
        self.resetLocalMetadata = resetLocalMetadata
        self.close = close
    }

    public static func live(_ store: PersistenceStore) -> SessionPersistenceClient {
        .init(
            restoreMetadata: { try await store.restoreMetadata() },
            createThread: { try await store.createThread($0) },
            replaceSelectedThread: { try await store.replaceSelectedThread(
                expectedSelectedThreadID: $0,
                with: $1
            ) },
            removeSelectedThread: { try await store.removeSelectedThread(
                expectedSelectedThreadID: $0
            ) },
            updateSelectedVibePath: { try await store.updateSelectedVibePath($0) },
            resetLocalMetadata: { try await store.resetLocalMetadata() },
            close: { try await store.close() }
        )
    }
}

public struct SessionModelDependencies: Sendable {
    public var persistence: SessionPersistenceClient
    public var validateRepository: @Sendable (URL) async throws -> CanonicalRepository
    public var locateExecutable: @Sendable (String?) throws -> VibeExecutable
    public var validateExecutable: @Sendable (URL) throws -> VibeExecutable
    public var makeRuntime: @Sendable (VibeExecutable, URL) -> any SessionRuntime
    public var makeAuthenticationOwner: @Sendable (VibeExecutable) -> any SessionAuthenticationOwner
    public var makeAuthenticationCandidate: @Sendable (VibeExecutable) -> any SessionAuthenticationCandidate
    public var makeUUID: @Sendable () -> UUID

    public init(
        persistence: SessionPersistenceClient,
        validateRepository: @escaping @Sendable (URL) async throws -> CanonicalRepository = {
            try await RepositoryValidator().validate($0)
        },
        locateExecutable: @escaping @Sendable (String?) throws -> VibeExecutable,
        validateExecutable: @escaping @Sendable (URL) throws -> VibeExecutable,
        makeRuntime: @escaping @Sendable (VibeExecutable, URL) -> any SessionRuntime,
        makeAuthenticationOwner: @escaping @Sendable (VibeExecutable) -> any SessionAuthenticationOwner,
        makeAuthenticationCandidate: @escaping @Sendable (VibeExecutable) -> any SessionAuthenticationCandidate,
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.persistence = persistence
        self.validateRepository = validateRepository
        self.locateExecutable = locateExecutable
        self.validateExecutable = validateExecutable
        self.makeRuntime = makeRuntime
        self.makeAuthenticationOwner = makeAuthenticationOwner
        self.makeAuthenticationCandidate = makeAuthenticationCandidate
        self.makeUUID = makeUUID
    }

    public static func live(
        store: PersistenceStore,
        adapter: VibeAdapter = VibeAdapter(),
        neutralApplicationSupportURL: URL
    ) -> SessionModelDependencies {
        .init(
            persistence: .live(store),
            locateExecutable: { storedPath in
                try adapter.locate(storedPath: storedPath)
            },
            validateExecutable: { try adapter.validateExecutable($0) },
            makeRuntime: { executable, cwd in
                LiveSessionRuntime(
                    executable: executable,
                    workingDirectory: cwd,
                    adapter: adapter
                )
            },
            makeAuthenticationOwner: { executable in
                AuthCoordinator(
                    adapter: adapter,
                    executable: executable,
                    neutralWorkingDirectory: neutralApplicationSupportURL
                )
            },
            makeAuthenticationCandidate: { executable in
                LiveSessionAuthenticationCandidate(candidate: adapter.makeAuthenticationCandidate(
                    executable: executable,
                    neutralWorkingDirectory: neutralApplicationSupportURL
                ))
            }
        )
    }
}
