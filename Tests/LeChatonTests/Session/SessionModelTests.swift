import Foundation
import Testing
@testable import LeChatonCore

@MainActor
@Suite("Session model orchestration", .serialized)
struct SessionModelTests {
    @Test("Launch restoration is metadata-only and requires explicit Resume")
    func metadataOnlyRestore() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        let metadata = makeMetadata(repositoryURL: repository.url)
        let persistence = FakeSessionPersistence(snapshot: .init(
            settings: .init(selectedVibePath: "/bin/echo", selectedThreadID: metadata.thread.id),
            selectedThread: metadata
        ))
        let runtimeFactory = LockedRuntimeQueue([])
        let authFactory = LockedAuthQueue([])
        let model = SessionModel(dependencies: makeDependencies(
            persistence: persistence,
            runtimeFactory: runtimeFactory,
            authFactory: authFactory
        ))

        await model.restoreLaunchMetadata()

        #expect(model.lifecycle == .unloaded)
        #expect(model.selectedThread == metadata)
        #expect(model.sessionState == SessionState())
        #expect(runtimeFactory.makeCount == 0)
        #expect(authFactory.makeCount == 0)
        #expect(model.canResume)
        await model.shutdown()
    }

    @Test("Replay publishes only after the current generation and attempt reach the barrier")
    func replayBarrierPublication() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        let metadata = makeMetadata(repositoryURL: repository.url)
        let attempt = UUID()
        let runtime = FakeSessionRuntime(
            loadBehavior: .success(
                attemptID: attempt,
                events: [
                    .init(sequence: 1, payload: .agentMessage(
                        messageID: "message-1",
                        content: .text("Hello", metadata: nil),
                        metadata: nil
                    )),
                    .init(sequence: 2, payload: .unknown(
                        kind: "future_replay_update",
                        raw: .object(["future": .bool(true)])
                    )),
                ],
                barrierAttemptID: attempt,
                throughSequence: 2,
                configurationOptions: [configurationOption(current: "small")]
            )
        )
        let model = makeRestorableModel(
            metadata: metadata,
            persistence: FakeSessionPersistence(metadata: metadata),
            runtimes: [runtime]
        )

        await model.restoreLaunchMetadata()
        await model.resume()

        #expect(model.lifecycle == .idle)
        #expect(model.sessionState.messages.map(\.text) == ["Hello"])
        #expect(model.sessionState.unknownUpdateCount == 1)
        #expect(model.sessionState.lastAppliedSequence == 2)
        #expect(model.configurationOptions.first?.currentValue == .string("small"))
        await model.shutdown()
    }

    @Test("Generation and load-attempt mismatches never publish staged history")
    func replayIdentityMismatch() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        let metadata = makeMetadata(repositoryURL: repository.url)

        let envelopeAttempt = UUID()
        let mismatchedAttempt = FakeSessionRuntime(
            loadBehavior: .success(
                attemptID: envelopeAttempt,
                events: [.init(sequence: 1, payload: .agentMessage(
                    messageID: "staged",
                    content: .text("Must not publish", metadata: nil),
                    metadata: nil
                ))],
                barrierAttemptID: UUID(),
                throughSequence: 1,
                configurationOptions: []
            )
        )
        let attemptModel = makeRestorableModel(
            metadata: metadata,
            persistence: FakeSessionPersistence(metadata: metadata),
            runtimes: [mismatchedAttempt]
        )
        await attemptModel.restoreLaunchMetadata()
        await attemptModel.resume()
        #expect(isFailed(attemptModel.lifecycle))
        #expect(attemptModel.sessionState.messages.isEmpty)

        let staleGeneration = FakeSessionRuntime(
            loadBehavior: .success(
                attemptID: envelopeAttempt,
                events: [.init(
                    generation: UUID(),
                    sequence: 1,
                    payload: .agentMessage(
                        messageID: "stale",
                        content: .text("Must not publish", metadata: nil),
                        metadata: nil
                    )
                )],
                barrierAttemptID: envelopeAttempt,
                throughSequence: 1,
                configurationOptions: [],
                finishUpdatesAfterLoad: true
            )
        )
        let generationModel = makeRestorableModel(
            metadata: metadata,
            persistence: FakeSessionPersistence(metadata: metadata),
            runtimes: [staleGeneration]
        )
        await generationModel.restoreLaunchMetadata()
        await generationModel.resume()
        #expect(isFailed(generationModel.lifecycle))
        #expect(generationModel.sessionState.messages.isEmpty)
    }

    @Test("A failed load discards partial staging and never creates a replacement session")
    func failedLoadDiscardsStaging() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        let metadata = makeMetadata(repositoryURL: repository.url)
        let runtime = FakeSessionRuntime(loadBehavior: .failure(
            attemptID: UUID(),
            events: [.init(sequence: 1, payload: .agentMessage(
                messageID: "partial",
                content: .text("Partial", metadata: nil),
                metadata: nil
            ))],
            error: .replayStreamEnded
        ))
        let model = makeRestorableModel(
            metadata: metadata,
            persistence: FakeSessionPersistence(metadata: metadata),
            runtimes: [runtime]
        )

        await model.restoreLaunchMetadata()
        await model.resume()

        #expect(isFailed(model.lifecycle))
        #expect(model.selectedThread == metadata)
        #expect(model.sessionState.messages.isEmpty)
        #expect(await runtime.newSessionCallCount == 0)
        #expect(model.issue?.actions.contains(.retry) == true)
    }

    @Test("Thread replacement verifies old cleanup before creating the sole replacement runtime")
    func replacementCleanupBeforeCreate() async throws {
        let oldRepository = try TestRepository(name: "old")
        let newRepository = try TestRepository(name: "new")
        defer {
            oldRepository.remove()
            newRepository.remove()
        }
        let log = OperationLog()
        let metadata = makeMetadata(repositoryURL: oldRepository.url)
        let persistence = FakeSessionPersistence(metadata: metadata, log: log)
        let loadAttempt = UUID()
        let oldRuntime = FakeSessionRuntime(
            label: "old",
            log: log,
            loadBehavior: .success(
                attemptID: loadAttempt,
                events: [],
                barrierAttemptID: loadAttempt,
                throughSequence: 0,
                configurationOptions: []
            )
        )
        let replacementRuntime = FakeSessionRuntime(label: "replacement", log: log)
        let model = makeRestorableModel(
            metadata: metadata,
            persistence: persistence,
            runtimes: [oldRuntime, replacementRuntime]
        )
        await model.restoreLaunchMetadata()
        await model.resume()

        await model.replaceSavedThread(repositoryURL: newRepository.url, title: "Replacement")

        #expect(model.lifecycle == .idle)
        #expect(model.selectedThread?.thread.vibeSessionID == "new-session-replacement")
        let events = await log.events
        let oldStop = try #require(events.firstIndex(of: "old.stop"))
        let replacementStart = try #require(events.firstIndex(of: "replacement.start"))
        let replacementNew = try #require(events.firstIndex(of: "replacement.new"))
        let commit = try #require(events.firstIndex(of: "persistence.replace"))
        #expect(oldStop < replacementStart)
        #expect(replacementStart < replacementNew)
        #expect(replacementNew < commit)
        await model.shutdown()
    }

    @Test("Executable swap persists, disposes old owners, then atomically publishes candidate")
    func executableSwapOrder() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        let log = OperationLog()
        let metadata = makeMetadata(repositoryURL: repository.url)
        let persistence = FakeSessionPersistence(metadata: metadata, log: log)
        let attempt = UUID()
        let runtime = FakeSessionRuntime(
            label: "session",
            log: log,
            loadBehavior: .success(
                attemptID: attempt,
                events: [],
                barrierAttemptID: attempt,
                throughSequence: 0,
                configurationOptions: []
            )
        )
        let oldAuth = FakeAuthenticationOwner(label: "old-auth", log: log)
        let promotedAuth = FakeAuthenticationOwner(label: "candidate-auth", log: log)
        let candidate = FakeAuthenticationCandidate(
            promotedOwner: promotedAuth,
            log: log
        )
        let candidateQueue = LockedCandidateQueue([candidate])
        let dependencies = makeDependencies(
            persistence: persistence,
            runtimeFactory: LockedRuntimeQueue([runtime]),
            authFactory: LockedAuthQueue([oldAuth]),
            candidateFactory: candidateQueue,
            validateExecutable: { _ in testExecutable(path: "/bin/cat") }
        )
        let model = SessionModel(dependencies: dependencies)
        await model.restoreLaunchMetadata()
        await model.resume()
        await model.validateExecutableCandidate(URL(filePath: "/bin/cat"))
        await model.commitExecutableCandidate()

        #expect(model.lifecycle == .unloaded)
        #expect(model.selectedVibePath == "/bin/cat")
        #expect(model.sessionState == SessionState())
        let events = await log.events
        let persisted = try #require(events.firstIndex(of: "persistence.path"))
        let runtimeStopped = try #require(events.firstIndex(of: "session.stop"))
        let authStopped = try #require(events.firstIndex(of: "old-auth.dispose"))
        let promoted = try #require(events.firstIndex(of: "candidate.promote"))
        #expect(persisted < runtimeStopped)
        #expect(runtimeStopped < authStopped)
        #expect(authStopped < promoted)
        await model.shutdown()
    }

    @Test("Configuration mismatch retains a disabled known-good snapshot and requires Resume")
    func configurationMismatch() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        let metadata = makeMetadata(repositoryURL: repository.url)
        let firstAttempt = UUID()
        let first = FakeSessionRuntime(loadBehavior: .success(
            attemptID: firstAttempt,
            events: [.init(sequence: 1, payload: .agentMessage(
                messageID: "known-good",
                content: .text("Known good", metadata: nil),
                metadata: nil
            ))],
            barrierAttemptID: firstAttempt,
            throughSequence: 1,
            configurationOptions: [configurationOption(current: "small")]
        ))
        let secondAttempt = UUID()
        let second = FakeSessionRuntime(loadBehavior: .success(
            attemptID: secondAttempt,
            events: [.init(sequence: 1, payload: .agentMessage(
                messageID: "candidate",
                content: .text("Candidate history", metadata: nil),
                metadata: nil
            ))],
            barrierAttemptID: secondAttempt,
            throughSequence: 1,
            configurationOptions: [configurationOption(current: "small")]
        ))
        let model = makeRestorableModel(
            metadata: metadata,
            persistence: FakeSessionPersistence(metadata: metadata),
            runtimes: [first, second]
        )
        await model.restoreLaunchMetadata()
        await model.resume()

        await model.applyConfiguration(optionID: "model", value: .string("large"))

        #expect(model.lifecycle == .reloadRequired)
        #expect(model.sessionState.messages.isEmpty)
        #expect(model.knownGoodSnapshot?.state.messages.map(\.text) == ["Known good"])
        #expect(model.configurationState == .reloadRequired(
            optionID: "model",
            requestedValue: .string("large")
        ))
        #expect(model.issue?.kind == .configurationReloadRequired)
    }

    @Test("Permissions stay FIFO and cancellation cannot trap an in-flight decision")
    func permissionRaceIsExactlyOnce() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        let metadata = makeMetadata(repositoryURL: repository.url)
        let attempt = UUID()
        let runtime = FakeSessionRuntime(
            loadBehavior: .success(
                attemptID: attempt,
                events: [],
                barrierAttemptID: attempt,
                throughSequence: 0,
                configurationOptions: []
            ),
            holdPrompt: true,
            holdPermissionResponse: true
        )
        let model = makeRestorableModel(
            metadata: metadata,
            persistence: FakeSessionPersistence(metadata: metadata),
            runtimes: [runtime]
        )
        await model.restoreLaunchMetadata()
        await model.resume()
        let prompt = Task { try await model.sendPrompt("permission test") }
        await waitUntil { model.lifecycle == .prompting }
        let firstID = RPCID.string("permission-1")
        let secondID = RPCID.integer(2)
        await runtime.emitPermission(id: firstID, sessionID: metadata.thread.vibeSessionID)
        await runtime.emitPermission(id: secondID, sessionID: metadata.thread.vibeSessionID)
        await waitUntil { model.pendingPermissions.count == 2 }

        await #expect(throws: SessionModelError.self) {
            try await model.resolvePermission(requestID: secondID, selectedOptionID: "allow")
        }
        let decision = Task {
            try await model.resolvePermission(requestID: firstID, selectedOptionID: "allow")
        }
        await waitUntil { await runtime.permissionResponseIsWaiting }
        await model.cancelPrompt()
        await runtime.releasePermissionResponse()
        try await decision.value
        _ = try? await prompt.value
        #expect(await runtime.selectedPermissionReplies == [firstID])
    }

    @Test("Cleanup Required retains the runtime owner until verified retry succeeds")
    func cleanupSurvivorRetry() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        let metadata = makeMetadata(repositoryURL: repository.url)
        let attempt = UUID()
        let survivor = ProcessIdentity(pid: 42_424, processStartTime: 7)
        let runtime = FakeSessionRuntime(
            loadBehavior: .success(
                attemptID: attempt,
                events: [],
                barrierAttemptID: attempt,
                throughSequence: 0,
                configurationOptions: []
            ),
            cleanupReports: [
                .init(signalled: [survivor], forceKilled: [], survivors: [survivor]),
                .init(signalled: [survivor], forceKilled: [survivor], survivors: []),
            ]
        )
        let model = makeRestorableModel(
            metadata: metadata,
            persistence: FakeSessionPersistence(metadata: metadata),
            runtimes: [runtime]
        )
        await model.restoreLaunchMetadata()
        await model.resume()
        await model.unload()
        #expect(model.lifecycle == .cleanupRequired)
        #expect(model.hasPendingCleanup)

        await model.retryCleanup()
        #expect(model.lifecycle == .unloaded)
        #expect(!model.hasPendingCleanup)
        #expect(await runtime.cleanupAttemptCount == 2)
    }

    @Test("An advertised repository trust decision continues New Thread into an idle chat")
    func repositoryTrustContinuesNewThread() async throws {
        let repository = try TestRepository(name: "trust")
        defer { repository.remove() }
        let first = FakeSessionRuntime(trustStatus: untrustedRepositoryStatus(cwd: repository.url))
        let resolver = FakeSessionRuntime(
            trustStatus: untrustedRepositoryStatus(cwd: repository.url),
            trustDecisionStatus: trustedRepositoryStatus()
        )
        let final = FakeSessionRuntime(trustStatus: trustedRepositoryStatus())
        let persistence = FakeSessionPersistence(snapshot: .init(
            settings: .init(selectedVibePath: nil, selectedThreadID: nil),
            selectedThread: nil
        ))
        let model = SessionModel(dependencies: makeDependencies(
            persistence: persistence,
            runtimeFactory: LockedRuntimeQueue([first, resolver, final]),
            authFactory: LockedAuthQueue([])
        ))

        await model.restoreLaunchMetadata()
        await model.createThread(repositoryURL: repository.url, title: "Trust Project")
        #expect(model.issue?.kind == .trustRequired)
        #expect(model.selectedThread == nil)

        await model.resolveRepositoryTrust(decision: "trust_repo")

        #expect(model.lifecycle == .idle)
        #expect(model.selectedThread?.thread.title == "Trust Project")
        let canonicalRepository = try RepositoryValidator().validate(repository.url)
        #expect(model.selectedThread?.environment.cwd == canonicalRepository.path)
        #expect(await resolver.appliedTrustDecisions == ["trust_repo"])
        #expect(await final.newSessionCallCount == 1)
        await model.shutdown()
    }
}

private struct FakeReplayEvent: Sendable {
    let generation: UUID?
    let sequence: UInt64
    let payload: SessionUpdate

    init(generation: UUID? = nil, sequence: UInt64, payload: SessionUpdate) {
        self.generation = generation
        self.sequence = sequence
        self.payload = payload
    }
}

private enum FakeLoadBehavior: Sendable {
    case success(
        attemptID: UUID,
        events: [FakeReplayEvent],
        barrierAttemptID: UUID,
        throughSequence: UInt64,
        configurationOptions: [JSONValue],
        finishUpdatesAfterLoad: Bool = false
    )
    case failure(attemptID: UUID, events: [FakeReplayEvent], error: SessionModelError)
}

private actor FakeSessionRuntime: SessionRuntime {
    private let label: String
    private let log: OperationLog?
    private let generation = UUID()
    private let loadBehavior: FakeLoadBehavior
    private let updateStream: AsyncStream<EventEnvelope<SessionUpdate>>
    private let updateContinuation: AsyncStream<EventEnvelope<SessionUpdate>>.Continuation
    private let requestStream: AsyncStream<IncomingACPRequest>
    private let requestContinuation: AsyncStream<IncomingACPRequest>.Continuation
    private let diagnosticStream: AsyncStream<ACPDiagnostic>
    private let diagnosticContinuation: AsyncStream<ACPDiagnostic>.Continuation
    private(set) var newSessionCallCount = 0
    private let holdPrompt: Bool
    private let holdPermissionResponse: Bool
    private let trustStatus: VibeRepositoryTrustStatus
    private let trustDecisionStatus: VibeRepositoryTrustStatus
    private var promptContinuation: CheckedContinuation<PromptResult, Never>?
    private var permissionContinuation: CheckedContinuation<Void, Never>?
    private(set) var selectedPermissionReplies: [RPCID] = []
    private(set) var appliedTrustDecisions: [String] = []
    private var cleanupReports: [ProcessCleanupReport]
    private(set) var cleanupAttemptCount = 0

    init(
        label: String = "runtime",
        log: OperationLog? = nil,
        loadBehavior: FakeLoadBehavior? = nil,
        holdPrompt: Bool = false,
        holdPermissionResponse: Bool = false,
        cleanupReports: [ProcessCleanupReport] = [],
        trustStatus: VibeRepositoryTrustStatus = trustedRepositoryStatus(),
        trustDecisionStatus: VibeRepositoryTrustStatus = trustedRepositoryStatus()
    ) {
        self.label = label
        self.log = log
        let defaultAttempt = UUID()
        self.loadBehavior = loadBehavior ?? .success(
            attemptID: defaultAttempt,
            events: [],
            barrierAttemptID: defaultAttempt,
            throughSequence: 0,
            configurationOptions: []
        )
        self.holdPrompt = holdPrompt
        self.holdPermissionResponse = holdPermissionResponse
        self.trustStatus = trustStatus
        self.trustDecisionStatus = trustDecisionStatus
        self.cleanupReports = cleanupReports
        (updateStream, updateContinuation) = AsyncStream.makeStream(of: EventEnvelope<SessionUpdate>.self)
        (requestStream, requestContinuation) = AsyncStream.makeStream(of: IncomingACPRequest.self)
        (diagnosticStream, diagnosticContinuation) = AsyncStream.makeStream(of: ACPDiagnostic.self)
    }

    func start() async throws -> SessionRuntimeStart {
        await log?.append("\(label).start")
        return .init(generation: generation, compatibility: testCompatibility())
    }

    func updates() async -> AsyncStream<EventEnvelope<SessionUpdate>> { updateStream }
    func incomingRequests() async -> AsyncStream<IncomingACPRequest> { requestStream }
    func diagnostics() async -> AsyncStream<ACPDiagnostic> { diagnosticStream }
    func failure() async -> ACPTransportError? { nil }

    func repositoryTrustStatus(cwd _: URL) async throws -> VibeRepositoryTrustStatus {
        trustStatus
    }

    func applyRepositoryTrustDecision(
        cwd _: URL,
        decision: String
    ) async throws -> VibeRepositoryTrustStatus {
        appliedTrustDecisions.append(decision)
        return trustDecisionStatus
    }

    func newSession(cwd _: URL) async throws -> NewSessionResult {
        newSessionCallCount += 1
        await log?.append("\(label).new")
        return .init(
            sessionID: "new-session-\(label)",
            configurationOptions: [],
            metadata: nil,
            raw: .object(["sessionId": .string("new-session-\(label)")])
        )
    }

    func loadSession(sessionID _: String, cwd _: URL) async throws -> LoadSessionResult {
        await log?.append("\(label).load")
        switch loadBehavior {
        case let .success(attemptID, events, barrierAttemptID, throughSequence, options, finish):
            yield(events, attemptID: attemptID)
            if finish { updateContinuation.finish() }
            return .init(
                barrier: .init(
                    runtimeGeneration: generation,
                    loadAttemptID: barrierAttemptID,
                    throughSequence: throughSequence
                ),
                configurationOptions: options,
                metadata: nil,
                raw: .object([:])
            )
        case let .failure(attemptID, events, error):
            yield(events, attemptID: attemptID)
            throw error
        }
    }

    func prompt(sessionID _: String, text _: String) async throws -> PromptResult {
        if holdPrompt {
            return await withCheckedContinuation { promptContinuation = $0 }
        }
        return promptResult()
    }

    func setConfigurationOption(
        sessionID _: String,
        optionID _: String,
        kind _: VibeConfigurationOption.Kind,
        value _: JSONValue
    ) async throws -> VibeConfigurationWriteResult {
        .init(options: [], metadata: nil, raw: .object([:]))
    }

    func respondToPermission(id: RPCID, selectedOptionID _: String) async throws {
        if holdPermissionResponse {
            await withCheckedContinuation { permissionContinuation = $0 }
        }
        selectedPermissionReplies.append(id)
    }
    func respondToPermissionCancellation(id _: RPCID) async throws {}
    func cancelPrompt(sessionID _: String) async throws -> Bool {
        promptContinuation?.resume(returning: promptResult())
        promptContinuation = nil
        return true
    }

    func stop() async -> ProcessCleanupReport? {
        await log?.append("\(label).stop")
        updateContinuation.finish()
        requestContinuation.finish()
        diagnosticContinuation.finish()
        return nextCleanupReport()
    }

    func retryCleanup() async throws -> ProcessCleanupReport? {
        nextCleanupReport()
    }

    var permissionResponseIsWaiting: Bool { permissionContinuation != nil }

    func releasePermissionResponse() {
        permissionContinuation?.resume()
        permissionContinuation = nil
    }

    func emitPermission(id: RPCID, sessionID: String) {
        requestContinuation.yield(.init(
            id: id,
            method: "session/request_permission",
            params: .object([
                "sessionId": .string(sessionID),
                "toolCall": .object(["toolCallId": .string("tool")]),
                "options": .array([.object([
                    "optionId": .string("allow"),
                    "name": .string("Allow"),
                    "kind": .string("allow_once"),
                ])]),
            ]),
            metadata: nil
        ))
    }

    private func nextCleanupReport() -> ProcessCleanupReport {
        cleanupAttemptCount += 1
        if !cleanupReports.isEmpty { return cleanupReports.removeFirst() }
        return .init(signalled: [], forceKilled: [], survivors: [])
    }

    private func promptResult() -> PromptResult {
        .init(stopReason: .endTurn, metadata: nil, raw: .object(["stopReason": .string("end_turn")]))
    }

    private func yield(_ events: [FakeReplayEvent], attemptID: UUID) {
        for event in events {
            updateContinuation.yield(.init(
                runtimeGeneration: event.generation ?? generation,
                loadAttemptID: attemptID,
                sequence: event.sequence,
                deliveryPhase: .loadPending,
                payload: event.payload
            ))
        }
    }
}

private actor FakeAuthenticationOwner: SessionAuthenticationOwner {
    let label: String
    let log: OperationLog?

    init(label: String = "auth", log: OperationLog? = nil) {
        self.label = label
        self.log = log
    }

    func refresh() async throws -> VibeAuthenticationSnapshot {
        await log?.append("\(label).refresh")
        return authenticatedSnapshot()
    }

    func dispose() async throws -> ProcessCleanupReport? {
        await log?.append("\(label).dispose")
        return .init(signalled: [], forceKilled: [], survivors: [])
    }

    func retryCleanup() async throws -> ProcessCleanupReport? {
        .init(signalled: [], forceKilled: [], survivors: [])
    }
}

private actor FakeAuthenticationCandidate: SessionAuthenticationCandidate {
    private let promotedOwner: any SessionAuthenticationOwner
    private let log: OperationLog?

    init(promotedOwner: any SessionAuthenticationOwner, log: OperationLog? = nil) {
        self.promotedOwner = promotedOwner
        self.log = log
    }

    func refresh() async throws -> VibeAuthenticationSnapshot {
        await log?.append("candidate.refresh")
        return authenticatedSnapshot(executable: testExecutable(path: "/bin/cat"))
    }

    func startDelegatedAuthentication() async throws -> VibeDelegatedAuthenticationAttempt {
        .init(id: "attempt", signInURL: URL(string: "https://example.test")!, expiresAt: nil, raw: .object([:]))
    }

    func completeDelegatedAuthentication(attemptID _: String) async throws -> VibeAuthenticationStatus {
        VibeAuthenticationStatus(raw: .object(["authenticated": .bool(true)]))
    }

    func promote() async throws -> SessionAuthenticationPromotion {
        await log?.append("candidate.promote")
        return .init(
            owner: promotedOwner,
            snapshot: authenticatedSnapshot(executable: testExecutable(path: "/bin/cat"))
        )
    }

    func dispose() async throws -> ProcessCleanupReport? {
        await log?.append("candidate.dispose")
        return .init(signalled: [], forceKilled: [], survivors: [])
    }

    func retryCleanup() async throws -> ProcessCleanupReport? {
        .init(signalled: [], forceKilled: [], survivors: [])
    }
}

private actor FakeSessionPersistence {
    private var snapshot: PersistenceSnapshot
    private let log: OperationLog?

    init(snapshot: PersistenceSnapshot, log: OperationLog? = nil) {
        self.snapshot = snapshot
        self.log = log
    }

    init(metadata: SavedThreadMetadata, log: OperationLog? = nil) {
        snapshot = .init(
            settings: .init(
                selectedVibePath: "/bin/echo",
                selectedThreadID: metadata.thread.id
            ),
            selectedThread: metadata
        )
        self.log = log
    }

    nonisolated func client() -> SessionPersistenceClient {
        .init(
            restoreMetadata: { await self.snapshotValue() },
            createThread: { request in try await self.create(request) },
            replaceSelectedThread: { oldID, request in
                try await self.replace(oldID: oldID, request: request)
            },
            removeSelectedThread: { id in try await self.remove(id: id) },
            updateSelectedVibePath: { url in await self.updatePath(url) },
            resetLocalMetadata: { await self.reset() },
            close: {}
        )
    }

    private func snapshotValue() -> PersistenceSnapshot { snapshot }

    private func create(_ request: CreateThreadRequest) throws -> SavedThreadMetadata {
        let metadata = metadata(from: request)
        snapshot = .init(
            settings: .init(selectedVibePath: snapshot.settings.selectedVibePath, selectedThreadID: request.threadID),
            selectedThread: metadata
        )
        return metadata
    }

    private func replace(oldID: UUID, request: CreateThreadRequest) async throws -> SavedThreadMetadata {
        guard snapshot.settings.selectedThreadID == oldID else { throw SessionModelError.noSavedThread }
        await log?.append("persistence.replace")
        return try create(request)
    }

    private func remove(id: UUID) throws -> SavedThreadMetadata {
        guard snapshot.settings.selectedThreadID == id, let selected = snapshot.selectedThread else {
            throw SessionModelError.noSavedThread
        }
        snapshot = .init(
            settings: .init(selectedVibePath: snapshot.settings.selectedVibePath, selectedThreadID: nil),
            selectedThread: nil
        )
        return selected
    }

    private func updatePath(_ url: URL?) async -> AppSettingsMetadata {
        await log?.append("persistence.path")
        let settings = AppSettingsMetadata(
            selectedVibePath: url?.path,
            selectedThreadID: snapshot.settings.selectedThreadID
        )
        snapshot = .init(settings: settings, selectedThread: snapshot.selectedThread)
        return settings
    }

    private func reset() -> PersistenceResetResult {
        let empty = PersistenceSnapshot(
            settings: .init(selectedVibePath: nil, selectedThreadID: nil),
            selectedThread: nil
        )
        snapshot = empty
        return .init(backupDirectory: URL(filePath: "/tmp/recovery"), restoredSnapshot: empty)
    }

    private func metadata(from request: CreateThreadRequest) -> SavedThreadMetadata {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return .init(
            project: .init(
                id: request.projectID,
                canonicalPath: request.repositoryURL.path,
                displayName: request.repositoryURL.lastPathComponent,
                createdAt: now,
                lastOpenedAt: now
            ),
            thread: .init(
                id: request.threadID,
                projectID: request.projectID,
                vibeSessionID: request.vibeSessionID,
                title: request.title,
                createdAt: now,
                updatedAt: now
            ),
            environment: .init(
                threadID: request.threadID,
                cwd: request.repositoryURL.path,
                executionMode: .local
            )
        )
    }
}

private actor OperationLog {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
}

private final class LockedRuntimeQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [any SessionRuntime]
    private(set) var makeCount = 0

    init(_ values: [any SessionRuntime]) { self.values = values }

    func next() -> any SessionRuntime {
        lock.withLock {
            makeCount += 1
            return values.removeFirst()
        }
    }
}

private final class LockedAuthQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [any SessionAuthenticationOwner]
    private(set) var makeCount = 0

    init(_ values: [any SessionAuthenticationOwner]) { self.values = values }

    func next() -> any SessionAuthenticationOwner {
        lock.withLock {
            makeCount += 1
            if values.isEmpty { return FakeAuthenticationOwner() }
            return values.removeFirst()
        }
    }
}

private final class LockedCandidateQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [any SessionAuthenticationCandidate]

    init(_ values: [any SessionAuthenticationCandidate]) { self.values = values }

    func next() -> any SessionAuthenticationCandidate {
        lock.withLock { values.removeFirst() }
    }
}

private struct TestRepository {
    let url: URL

    init(name: String = "repository") throws {
        url = FileManager.default.temporaryDirectory.appending(
            path: "lechaton-session-model-\(name)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try runGit(["init", "-q"], at: url)
        try Data("baseline\n".utf8).write(to: url.appending(path: "README.md"))
        try runGit(["add", "README.md"], at: url)
        try runGit([
            "-c", "user.name=LeChaton Tests",
            "-c", "user.email=tests@example.invalid",
            "commit", "-q", "-m", "baseline",
        ], at: url)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    private func runGit(_ arguments: [String], at url: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = url
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SessionModelError.noSavedThread
        }
    }
}

@MainActor
private func makeRestorableModel(
    metadata: SavedThreadMetadata,
    persistence: FakeSessionPersistence,
    runtimes: [any SessionRuntime]
) -> SessionModel {
    SessionModel(dependencies: makeDependencies(
        persistence: persistence,
        runtimeFactory: LockedRuntimeQueue(runtimes),
        authFactory: LockedAuthQueue([])
    ))
}

private func makeDependencies(
    persistence: FakeSessionPersistence,
    runtimeFactory: LockedRuntimeQueue,
    authFactory: LockedAuthQueue,
    candidateFactory: LockedCandidateQueue = LockedCandidateQueue([]),
    validateExecutable: @escaping @Sendable (URL) throws -> VibeExecutable = { url in
        testExecutable(path: url.path)
    }
) -> SessionModelDependencies {
    .init(
        persistence: persistence.client(),
        locateExecutable: { _ in testExecutable() },
        validateExecutable: validateExecutable,
        makeRuntime: { _, _ in runtimeFactory.next() },
        makeAuthenticationOwner: { _ in authFactory.next() },
        makeAuthenticationCandidate: { _ in candidateFactory.next() }
    )
}

private func makeMetadata(repositoryURL: URL) -> SavedThreadMetadata {
    let projectID = UUID()
    let threadID = UUID()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return .init(
        project: .init(
            id: projectID,
            canonicalPath: repositoryURL.path,
            displayName: repositoryURL.lastPathComponent,
            createdAt: now,
            lastOpenedAt: now
        ),
        thread: .init(
            id: threadID,
            projectID: projectID,
            vibeSessionID: "saved-vibe-session",
            title: "Saved Thread",
            createdAt: now,
            updatedAt: now
        ),
        environment: .init(threadID: threadID, cwd: repositoryURL.path, executionMode: .local)
    )
}

private func trustedRepositoryStatus() -> VibeRepositoryTrustStatus {
    .init(raw: .object([
        "trust_status": .string("trusted"),
        "details": .null,
    ]))
}

private func untrustedRepositoryStatus(cwd: URL) -> VibeRepositoryTrustStatus {
    .init(raw: .object([
        "trust_status": .string("untrusted"),
        "details": .object([
            "cwd": .string(cwd.path),
            "availableDecisions": .array([
                .string("trust_repo"),
                .string("trust_cwd"),
                .string("decline"),
            ]),
        ]),
    ]))
}

private func configurationOption(current: String) -> JSONValue {
    .object([
        "id": .string("model"),
        "name": .string("Model"),
        "type": .string("select"),
        "currentValue": .string(current),
        "options": .array([
            .object(["value": .string("small"), "name": .string("Small")]),
            .object(["value": .string("large"), "name": .string("Large")]),
        ]),
    ])
}

private func testExecutable(path: String = "/bin/echo") -> VibeExecutable {
    .init(url: URL(filePath: path), source: .explicit)
}

private func testCompatibility(executable: VibeExecutable = testExecutable()) -> VibeCompatibility {
    try! .init(
        executable: executable,
        initialization: .init(
            protocolVersion: 1,
            agentInfo: .init(
                name: VibeCompatibility.supportedAgentName,
                title: "Vibe",
                version: VibeCompatibility.supportedVersion
            ),
            agentCapabilities: .object(["loadSession": .bool(true)]),
            authenticationMethods: [],
            metadata: nil,
            raw: .object([:])
        )
    )
}

private func authenticatedSnapshot(
    executable: VibeExecutable = testExecutable()
) -> VibeAuthenticationSnapshot {
    .init(
        compatibility: testCompatibility(executable: executable),
        status: .init(raw: .object(["authenticated": .bool(true)]))
    )
}

private func isFailed(_ lifecycle: SessionLifecycle) -> Bool {
    if case .failed = lifecycle { return true }
    return false
}

@MainActor
private func waitUntil(_ predicate: () async -> Bool) async {
    for _ in 0..<1_000 {
        if await predicate() { return }
        await Task.yield()
    }
    Issue.record("Condition did not become true")
}
