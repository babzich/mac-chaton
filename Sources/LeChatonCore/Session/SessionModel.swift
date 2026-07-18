import Foundation
import Observation

@MainActor
@Observable
public final class SessionModel {
    public private(set) var lifecycle: SessionLifecycle = .unloaded
    public private(set) var selectedThread: SavedThreadMetadata?
    public private(set) var selectedVibePath: String?
    public private(set) var sessionState = SessionState()
    public private(set) var knownGoodSnapshot: KnownGoodSnapshot?
    public private(set) var configurationOptions: [VibeConfigurationOption] = []
    public private(set) var configurationState: ConfigurationApplicationState = .effectiveFromVibe
    public private(set) var authentication: SessionAuthenticationPresentation = .unknown
    public private(set) var trust: SessionTrustPresentation = .unknown
    public private(set) var pendingPermissions: [PendingPermission] = []
    public private(set) var executableCandidate: ExecutableCandidatePresentation?
    public private(set) var activity: String?
    public private(set) var issue: SessionModelIssue?
    public private(set) var lastRecoveryBackupURL: URL?

    public var canResume: Bool {
        guard selectedThread != nil else { return false }
        return switch lifecycle {
        case .unloaded, .reloadRequired, .failed: true
        default: false
        }
    }

    public var canPrompt: Bool { lifecycle == .idle && activeRuntime?.sessionID != nil }
    public var hasPendingCleanup: Bool {
        pendingRuntimeCleanup != nil || pendingAuthCleanup != nil || pendingCandidateCleanup != nil
    }

    @ObservationIgnored private let dependencies: SessionModelDependencies
    @ObservationIgnored private var reducer = SessionReducer()
    @ObservationIgnored private var activeRuntime: ActiveRuntime?
    @ObservationIgnored private var loadContext: LoadContext?
    @ObservationIgnored private var authOwner: (any SessionAuthenticationOwner)?
    @ObservationIgnored private var authOwnerExecutablePath: String?
    @ObservationIgnored private var candidateContext: CandidateContext?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var diagnosticTask: Task<Void, Never>?
    @ObservationIgnored private var resolvedPermissionIDs: Set<RPCID> = []
    @ObservationIgnored private var handlingRuntimeFailure = false
    @ObservationIgnored private var pendingRuntimeCleanup: (any SessionRuntime)?
    @ObservationIgnored private var pendingAuthCleanup: (any SessionAuthenticationOwner)?
    @ObservationIgnored private var pendingCandidateCleanup: (any SessionAuthenticationCandidate)?
    @ObservationIgnored private var cleanupSuccessLifecycle: SessionLifecycle = .unloaded
    @ObservationIgnored private var pendingTrustAction: PendingTrustAction?

    private struct ActiveRuntime: Sendable {
        let id: UUID
        let owner: any SessionRuntime
        let generation: UUID
        var sessionID: String?
    }

    private struct LoadContext: Sendable {
        let runtimeID: UUID
        let generation: UUID
        var loadAttemptID: UUID?
        var reducer: SessionReducer
        var failure: SessionModelError?
    }

    private struct CandidateContext: Sendable {
        let executable: VibeExecutable
        let owner: any SessionAuthenticationCandidate
        var authentication: VibeAuthenticationStatus
        var pendingSignIn: VibeDelegatedAuthenticationAttempt?
    }

    private enum PendingTrustAction: Sendable {
        case create(repositoryURL: URL, title: String)
        case resume
        case replace(repositoryURL: URL, title: String)
    }

    public init(dependencies: SessionModelDependencies) {
        self.dependencies = dependencies
    }

    public convenience init(
        store: PersistenceStore,
        adapter: VibeAdapter = VibeAdapter(),
        neutralApplicationSupportURL: URL
    ) {
        self.init(dependencies: .live(
            store: store,
            adapter: adapter,
            neutralApplicationSupportURL: neutralApplicationSupportURL
        ))
    }

    /// Restores only app-owned metadata. No Vibe, auth, or candidate process is created here.
    public func restoreLaunchMetadata() async {
        guard activeRuntime == nil, authOwner == nil, candidateContext == nil else { return }
        activity = "Loading local metadata"
        issue = nil
        do {
            let snapshot = try await dependencies.persistence.restoreMetadata()
            selectedThread = snapshot.selectedThread
            selectedVibePath = snapshot.settings.selectedVibePath
            lifecycle = .unloaded
            clearRuntimePresentation(keepKnownGood: false)
        } catch {
            lifecycle = .failed(String(describing: error))
            issue = databaseIssue(error)
        }
        activity = nil
    }

    public func resume() async {
        guard selectedThread != nil else {
            issue = runtimeIssue(SessionModelError.noSavedThread)
            return
        }
        switch lifecycle {
        case .unloaded, .reloadRequired, .failed:
            break
        default:
            issue = runtimeIssue(SessionModelError.invalidLifecycle(
                expected: "Unloaded, Reload Required, or Failed",
                actual: lifecycle
            ))
            return
        }
        pendingTrustAction = nil

        let preserveKnownGood = lifecycle == .reloadRequired && knownGoodSnapshot != nil
        lifecycle = .loadingHistory
        issue = nil
        activity = "Validating repository and Vibe"
        do {
            let metadata = try requireSelectedThread()
            let cwd = URL(filePath: metadata.environment.cwd, directoryHint: .isDirectory)
            _ = try RepositoryValidator().validate(cwd)
            let executable = try dependencies.locateExecutable(selectedVibePath)
            let runtime = try await prepareRuntime(executable: executable, cwd: cwd)
            try await loadSelectedThread(
                runtimeID: runtime.id,
                expectedConfiguration: nil,
                preserveKnownGoodOnFailure: preserveKnownGood
            )
        } catch {
            if isRepositoryTrustRequired(error) { pendingTrustAction = .resume }
            await failLoadOrPreparation(error, preserveKnownGood: preserveKnownGood)
        }
        activity = nil
    }

    public func createThread(repositoryURL: URL, title: String) async {
        guard selectedThread == nil, activeRuntime == nil else {
            issue = runtimeIssue(SessionModelError.invalidLifecycle(
                expected: "no selected Thread",
                actual: lifecycle
            ))
            return
        }
        guard lifecycle == .unloaded || isFailed(lifecycle) else {
            issue = runtimeIssue(SessionModelError.invalidLifecycle(
                expected: "Unloaded",
                actual: lifecycle
            ))
            return
        }
        pendingTrustAction = nil

        lifecycle = .replacingThread
        issue = nil
        activity = "Creating Vibe session"
        do {
            let repository = try RepositoryValidator().validate(repositoryURL)
            let executable = try dependencies.locateExecutable(selectedVibePath)
            let runtime = try await prepareRuntime(
                executable: executable,
                cwd: URL(filePath: repository.path, directoryHint: .isDirectory)
            )
            let canonicalRepositoryURL = URL(
                filePath: repository.path,
                directoryHint: .isDirectory
            )
            let result = try await runtime.owner.newSession(cwd: canonicalRepositoryURL)
            guard activeRuntime?.id == runtime.id else { throw SessionModelError.staleRuntime }
            let decodedOptions = try decodeConfigurationOptions(result.configurationOptions)

            let request = CreateThreadRequest(
                projectID: dependencies.makeUUID(),
                threadID: dependencies.makeUUID(),
                repositoryURL: canonicalRepositoryURL,
                vibeSessionID: result.sessionID,
                title: title
            )
            let metadata: SavedThreadMetadata
            do {
                metadata = try await dependencies.persistence.createThread(request)
            } catch {
                let owner = invalidateRuntime(clearPresentation: true)
                try await stopVerified(owner)
                lifecycle = .unloaded
                issue = .init(
                    kind: .persistence,
                    title: "Thread was not saved",
                    message: "The Vibe session was created but local metadata failed to commit. An unreachable Vibe-side session may remain. \(error)",
                    actions: [.retry]
                )
                activity = nil
                return
            }

            // The transaction is authoritative from this point onward, even if the candidate
            // runtime failed while the database actor was committing.
            selectedThread = metadata
            guard activeRuntime?.id == runtime.id else {
                let owner = invalidateRuntime(clearPresentation: true)
                do {
                    try await stopVerified(owner)
                    lifecycle = .failed(SessionModelError.staleRuntime.description)
                    issue = runtimeIssue(SessionModelError.staleRuntime)
                } catch {
                    cleanupSuccessLifecycle = .unloaded
                    lifecycle = .cleanupRequired
                    issue = cleanupIssue(error)
                }
                activity = nil
                return
            }
            activeRuntime?.sessionID = result.sessionID
            reducer.reset()
            sessionState = reducer.state
            configurationOptions = decodedOptions
            configurationState = .effectiveFromVibe
            lifecycle = .idle
        } catch {
            if isRepositoryTrustRequired(error) {
                pendingTrustAction = .create(repositoryURL: repositoryURL, title: title)
            }
            await failLoadOrPreparation(error, preserveKnownGood: false)
        }
        activity = nil
    }

    /// Applies exactly one decision advertised by Vibe, then retries the
    /// interrupted create/load/replace operation through a fresh process.
    public func resolveRepositoryTrust(decision: String) async {
        guard let action = pendingTrustAction,
              case let .status(status) = trust,
              status.options.compactMap(\.stringValue).contains(decision)
        else {
            issue = runtimeIssue(SessionModelError.unsupportedTrustDecision(decision))
            return
        }

        let cwd: URL
        switch action {
        case let .create(repositoryURL, _), let .replace(repositoryURL, _):
            cwd = repositoryURL
        case .resume:
            guard let selectedThread else {
                pendingTrustAction = nil
                issue = runtimeIssue(SessionModelError.noSavedThread)
                return
            }
            cwd = URL(filePath: selectedThread.environment.cwd, directoryHint: .isDirectory)
        }

        lifecycle = .replacingThread
        activity = "Applying repository trust decision"
        do {
            let repository = try RepositoryValidator().validate(cwd)
            let canonicalCWD = URL(filePath: repository.path, directoryHint: .isDirectory)
            let executable = try dependencies.locateExecutable(selectedVibePath)
            let authSnapshot = try await ensureAuthentication(executable: executable, requireReady: true)
            authentication = .status(authSnapshot.status)

            let owner = dependencies.makeRuntime(executable, canonicalCWD)
            let started = try await owner.start()
            let active = ActiveRuntime(
                id: dependencies.makeUUID(),
                owner: owner,
                generation: started.generation,
                sessionID: nil
            )
            activeRuntime = active
            startConsumers(for: active)

            let updated = try await owner.applyRepositoryTrustDecision(
                cwd: canonicalCWD,
                decision: decision
            )
            guard activeRuntime?.id == active.id else { throw SessionModelError.staleRuntime }
            let stoppedOwner = invalidateRuntime(clearPresentation: true)
            try await stopVerified(stoppedOwner)
            trust = .status(updated)

            guard updated.state == .trusted else {
                pendingTrustAction = nil
                lifecycle = .unloaded
                issue = nil
                activity = nil
                return
            }

            pendingTrustAction = nil
            lifecycle = .unloaded
            issue = nil
            activity = nil
            switch action {
            case let .create(repositoryURL, title):
                await createThread(repositoryURL: repositoryURL, title: title)
            case .resume:
                await resume()
            case let .replace(repositoryURL, title):
                await replaceSavedThread(repositoryURL: repositoryURL, title: title)
            }
        } catch {
            await failLoadOrPreparation(error, preserveKnownGood: false)
            activity = nil
        }
    }

    public func replaceSavedThread(repositoryURL: URL, title: String) async {
        guard let oldMetadata = selectedThread else {
            await createThread(repositoryURL: repositoryURL, title: title)
            return
        }
        guard lifecycle == .unloaded || lifecycle == .idle else {
            issue = runtimeIssue(SessionModelError.invalidLifecycle(
                expected: "Unloaded or Idle",
                actual: lifecycle
            ))
            return
        }
        pendingTrustAction = nil

        lifecycle = .replacingThread
        issue = nil
        activity = "Stopping the current runtime"
        let oldOwner = invalidateRuntime(clearPresentation: true)
        do {
            try await stopVerified(oldOwner)
        } catch {
            selectedThread = oldMetadata
            cleanupSuccessLifecycle = .unloaded
            lifecycle = .cleanupRequired
            issue = cleanupIssue(error)
            activity = nil
            return
        }

        do {
            let repository = try RepositoryValidator().validate(repositoryURL)
            let executable = try dependencies.locateExecutable(selectedVibePath)
            activity = "Creating replacement session"
            let runtime = try await prepareRuntime(
                executable: executable,
                cwd: URL(filePath: repository.path, directoryHint: .isDirectory)
            )
            let canonicalRepositoryURL = URL(
                filePath: repository.path,
                directoryHint: .isDirectory
            )
            let newSession = try await runtime.owner.newSession(cwd: canonicalRepositoryURL)
            guard activeRuntime?.id == runtime.id else { throw SessionModelError.staleRuntime }
            let decodedOptions = try decodeConfigurationOptions(newSession.configurationOptions)
            let request = CreateThreadRequest(
                projectID: dependencies.makeUUID(),
                threadID: dependencies.makeUUID(),
                repositoryURL: canonicalRepositoryURL,
                vibeSessionID: newSession.sessionID,
                title: title
            )

            let replacement: SavedThreadMetadata
            do {
                replacement = try await dependencies.persistence.replaceSelectedThread(
                    oldMetadata.thread.id,
                    request
                )
            } catch {
                let owner = invalidateRuntime(clearPresentation: true)
                try await stopVerified(owner)
                selectedThread = oldMetadata
                lifecycle = .unloaded
                issue = .init(
                    kind: .persistence,
                    title: "Replacement was not committed",
                    message: "The original Thread remains selected and can be resumed. \(error)",
                    actions: [.retry, .removeSavedThread]
                )
                activity = nil
                return
            }

            // Replacement metadata is authoritative after the transaction returns. Never
            // restore the deleted old Thread in memory after this edge.
            selectedThread = replacement
            guard activeRuntime?.id == runtime.id else {
                let owner = invalidateRuntime(clearPresentation: true)
                do {
                    try await stopVerified(owner)
                    lifecycle = .failed(SessionModelError.staleRuntime.description)
                    issue = runtimeIssue(SessionModelError.staleRuntime)
                } catch {
                    cleanupSuccessLifecycle = .unloaded
                    lifecycle = .cleanupRequired
                    issue = cleanupIssue(error)
                }
                activity = nil
                return
            }
            activeRuntime?.sessionID = newSession.sessionID
            configurationOptions = decodedOptions
            configurationState = .effectiveFromVibe
            lifecycle = .idle
        } catch {
            if isRepositoryTrustRequired(error) {
                pendingTrustAction = .replace(repositoryURL: repositoryURL, title: title)
            }
            let owner = invalidateRuntime(clearPresentation: true)
            do {
                try await stopVerified(owner)
                selectedThread = oldMetadata
                lifecycle = .unloaded
                issue = runtimeIssue(error)
            } catch {
                selectedThread = oldMetadata
                cleanupSuccessLifecycle = .unloaded
                lifecycle = .cleanupRequired
                issue = cleanupIssue(error)
            }
        }
        activity = nil
    }

    @discardableResult
    public func sendPrompt(_ text: String) async throws -> PromptResult {
        guard lifecycle == .idle else {
            throw SessionModelError.invalidLifecycle(expected: "Idle", actual: lifecycle)
        }
        guard let runtime = activeRuntime, let sessionID = runtime.sessionID else {
            throw SessionModelError.noRuntime
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SessionModelError.invalidLifecycle(expected: "a non-empty prompt", actual: lifecycle)
        }

        issue = nil
        reducer.beginPrompt()
        sessionState = reducer.state
        lifecycle = .prompting
        activity = "Vibe is working"
        do {
            let result = try await runtime.owner.prompt(sessionID: sessionID, text: text)
            guard activeRuntime?.id == runtime.id else { throw SessionModelError.staleRuntime }
            if lifecycle != .cancelling {
                reducer.finishPrompt(failed: false)
                sessionState = reducer.state
                pendingPermissions.removeAll()
                lifecycle = .idle
                activity = nil
            }
            return result
        } catch {
            if lifecycle == .cancelling { throw error }
            reducer.finishPrompt(failed: true)
            sessionState = reducer.state
            await handleRuntimeFailure(error, preserveKnownGood: false)
            throw error
        }
    }

    public func resolvePermission(requestID: RPCID, selectedOptionID: String) async throws {
        guard let first = pendingPermissions.first, first.id == requestID else {
            throw SessionModelError.invalidLifecycle(
                expected: "the first pending permission",
                actual: lifecycle
            )
        }
        guard !resolvedPermissionIDs.contains(requestID) else { return }
        guard let runtime = activeRuntime else { throw SessionModelError.noRuntime }
        try await runtime.owner.respondToPermission(
            id: requestID,
            selectedOptionID: selectedOptionID
        )
        guard activeRuntime?.id == runtime.id else { throw SessionModelError.staleRuntime }
        resolvedPermissionIDs.insert(requestID)
        // Cancellation can win while the transport actor is answering. Remove by identity
        // after suspension rather than assuming the FIFO still contains its old first element.
        if let index = pendingPermissions.firstIndex(where: { $0.id == requestID }) {
            pendingPermissions.remove(at: index)
        }
    }

    public func cancelPrompt() async {
        if lifecycle == .cancelling { return }
        guard lifecycle == .prompting, let runtime = activeRuntime, let sessionID = runtime.sessionID else {
            return
        }
        lifecycle = .cancelling
        activity = "Cancelling and checking child processes"
        reducer.beginCancellation()
        sessionState = reducer.state
        do {
            _ = try await runtime.owner.cancelPrompt(sessionID: sessionID)
            guard activeRuntime?.id == runtime.id else { throw SessionModelError.staleRuntime }
            pendingPermissions.removeAll()
            reducer.finishPrompt(failed: false)
            sessionState = reducer.state
            lifecycle = .idle
            activity = nil
        } catch {
            pendingPermissions.removeAll()
            reducer.finishPrompt(failed: true)
            sessionState = reducer.state
            await handleRuntimeFailure(error, preserveKnownGood: false)
        }
    }

    public func unload() async {
        guard lifecycle == .idle || lifecycle == .unloaded || lifecycle == .reloadRequired || isFailed(lifecycle) else { return }
        lifecycle = .replacingThread
        activity = "Stopping Vibe"
        let owner = invalidateRuntime(clearPresentation: true)
        do {
            try await stopVerified(owner)
            lifecycle = .unloaded
            issue = nil
        } catch {
            cleanupSuccessLifecycle = .unloaded
            lifecycle = .cleanupRequired
            issue = cleanupIssue(error)
        }
        activity = nil
    }

    public func resetRuntime() async {
        await unload()
    }

    public func retryCleanup() async {
        guard lifecycle == .cleanupRequired || lifecycle == .swapFailed else { return }
        let destination = cleanupSuccessLifecycle
        activity = "Retrying verified process cleanup"
        let cleanupError = await retryPendingCleanupOwners()
        if let cleanupError {
            lifecycle = destination == .swapFailed ? .swapFailed : .cleanupRequired
            issue = cleanupIssue(cleanupError)
            if destination == .swapFailed {
                issue = .init(
                    kind: .swapFailed,
                    title: "Executable cleanup still failed",
                    message: String(describing: cleanupError),
                    actions: [.retryCleanup, .quit]
                )
            }
        } else {
            lifecycle = destination
            switch destination {
            case .swapFailed:
                issue = .init(
                    kind: .swapFailed,
                    title: "Executable candidate must be retried",
                    message: "Old process owners are gone. Revalidate the committed executable candidate before publishing a new owner.",
                    actions: [.retryCandidate, .quit]
                )
            case .reloadRequired:
                issue = .init(
                    kind: .configurationReloadRequired,
                    title: "Reload required",
                    message: "Process cleanup completed. Resume to reconcile Vibe’s effective configuration.",
                    actions: [.retry, .resetRuntime, .removeSavedThread]
                )
            default:
                issue = nil
            }
        }
        activity = nil
    }

    public func retryExecutableCandidate() async {
        guard lifecycle == .swapFailed, !hasPendingCleanup,
              let selectedVibePath, !selectedVibePath.isEmpty
        else { return }
        await validateExecutableCandidate(URL(filePath: selectedVibePath))
    }

    public func removeSavedThread() async {
        guard let selectedThread else { return }
        switch lifecycle {
        case .unloaded, .idle, .reloadRequired, .failed:
            break
        default:
            issue = runtimeIssue(SessionModelError.invalidLifecycle(
                expected: "Unloaded, Idle, Reload Required, or Failed",
                actual: lifecycle
            ))
            return
        }
        lifecycle = .replacingThread
        let owner = invalidateRuntime(clearPresentation: true)
        do {
            try await stopVerified(owner)
            _ = try await dependencies.persistence.removeSelectedThread(selectedThread.thread.id)
            self.selectedThread = nil
            lifecycle = .unloaded
            issue = nil
        } catch {
            if error is SessionModelError {
                cleanupSuccessLifecycle = .unloaded
                lifecycle = .cleanupRequired
                issue = cleanupIssue(error)
            } else {
                lifecycle = .unloaded
                issue = .init(
                    kind: .persistence,
                    title: "Saved Thread could not be removed",
                    message: String(describing: error),
                    actions: [.retry, .resetRuntime]
                )
            }
        }
    }

    public func applyConfiguration(optionID: String, value: JSONValue) async {
        guard lifecycle == .idle,
              let runtime = activeRuntime,
              let sessionID = runtime.sessionID,
              let option = configurationOptions.first(where: { $0.id == optionID })
        else {
            issue = runtimeIssue(SessionModelError.unsupportedConfiguration(optionID))
            return
        }
        guard option.values.count > 1, option.values.contains(value) else {
            issue = runtimeIssue(SessionModelError.unsupportedConfiguration(optionID))
            return
        }

        configurationState = .candidate(optionID: optionID, value: value)
        lifecycle = .loadingHistory
        await Task.yield()
        configurationState = .applying(optionID: optionID, value: value)
        activity = "Applying Vibe configuration"
        issue = nil
        knownGoodSnapshot = KnownGoodSnapshot(state: sessionState)

        do {
            _ = try await runtime.owner.setConfigurationOption(
                sessionID: sessionID,
                optionID: optionID,
                kind: option.kind,
                value: value
            )
            guard activeRuntime?.id == runtime.id else { throw SessionModelError.staleRuntime }

            let oldOwner = invalidateRuntime(clearPresentation: true, keepKnownGood: true)
            try await stopVerified(oldOwner)
            let metadata = try requireSelectedThread()
            let cwd = URL(filePath: metadata.environment.cwd, directoryHint: .isDirectory)
            let executable = try dependencies.locateExecutable(selectedVibePath)
            let fresh = try await prepareRuntime(executable: executable, cwd: cwd)
            try await loadSelectedThread(
                runtimeID: fresh.id,
                expectedConfiguration: (optionID, value),
                preserveKnownGoodOnFailure: true
            )
            configurationState = .effectiveFromVibe
        } catch {
            let owner = invalidateRuntime(clearPresentation: true, keepKnownGood: true)
            do {
                try await stopVerified(owner)
                lifecycle = .reloadRequired
                configurationState = .reloadRequired(optionID: optionID, requestedValue: value)
                issue = .init(
                    kind: .configurationReloadRequired,
                    title: "Reload required",
                    message: "Vibe may have changed its global configuration. Resume to reconcile the effective value. \(error)",
                    actions: [.retry, .resetRuntime, .removeSavedThread]
                )
            } catch {
                cleanupSuccessLifecycle = .reloadRequired
                lifecycle = .cleanupRequired
                configurationState = .reloadRequired(optionID: optionID, requestedValue: value)
                issue = cleanupIssue(error)
            }
        }
        activity = nil
    }

    public func validateExecutableCandidate(_ candidateURL: URL) async {
        guard lifecycle == .unloaded || lifecycle == .idle || lifecycle == .swapFailed else {
            issue = runtimeIssue(SessionModelError.invalidLifecycle(
                expected: "Unloaded, Idle, or Swap Failed",
                actual: lifecycle
            ))
            return
        }
        let previousLifecycle = lifecycle
        lifecycle = .validatingExecutable
        issue = nil
        activity = "Validating Vibe executable"
        var validatingOwner: (any SessionAuthenticationCandidate)?
        do {
            let executable = try dependencies.validateExecutable(candidateURL)
            let resolvedCurrentPath = authOwnerExecutablePath
                ?? (try? dependencies.locateExecutable(selectedVibePath).url.path)
            if previousLifecycle != .swapFailed, executable.url.path == resolvedCurrentPath {
                let snapshot = try await ensureAuthentication(executable: executable, requireReady: false)
                authentication = .status(snapshot.status)
                lifecycle = previousLifecycle
                activity = nil
                return
            }

            if let oldCandidate = candidateContext?.owner {
                try await disposeCandidateVerified(oldCandidate)
                candidateContext = nil
                executableCandidate = nil
            }
            let owner = dependencies.makeAuthenticationCandidate(executable)
            validatingOwner = owner
            let snapshot = try await owner.refresh()
            candidateContext = .init(
                executable: executable,
                owner: owner,
                authentication: snapshot.status,
                pendingSignIn: nil
            )
            validatingOwner = nil
            publishCandidatePresentation()
            lifecycle = previousLifecycle
        } catch {
            if let owner = validatingOwner ?? candidateContext?.owner {
                _ = try? await disposeCandidateVerified(owner)
            }
            candidateContext = nil
            executableCandidate = nil
            if hasPendingCleanup {
                cleanupSuccessLifecycle = previousLifecycle
                lifecycle = .cleanupRequired
            } else {
                lifecycle = previousLifecycle
            }
            await reconcileCurrentAuthentication()
            issue = hasPendingCleanup ? cleanupIssue(error) : runtimeIssue(error)
        }
        activity = nil
    }

    @discardableResult
    public func startCandidateAuthentication() async throws -> URL {
        guard var context = candidateContext else { throw SessionModelError.noExecutableCandidate }
        let prior = lifecycle
        lifecycle = .validatingExecutable
        defer { lifecycle = prior }
        do {
            let attempt = try await context.owner.startDelegatedAuthentication()
            context.pendingSignIn = attempt
            candidateContext = context
            publishCandidatePresentation()
            return attempt.signInURL
        } catch {
            await reconcileCurrentAuthentication()
            throw error
        }
    }

    public func completeCandidateAuthentication(attemptID: String) async throws {
        guard var context = candidateContext else { throw SessionModelError.noExecutableCandidate }
        let prior = lifecycle
        lifecycle = .validatingExecutable
        defer { lifecycle = prior }
        do {
            let status = try await context.owner.completeDelegatedAuthentication(attemptID: attemptID)
            context.authentication = status
            context.pendingSignIn = nil
            candidateContext = context
            publishCandidatePresentation()
        } catch {
            await reconcileCurrentAuthentication()
            throw error
        }
    }

    public func discardExecutableCandidate() async {
        guard let context = candidateContext else { return }
        let previousLifecycle = lifecycle
        lifecycle = .validatingExecutable
        do {
            try await disposeCandidateVerified(context.owner)
            lifecycle = previousLifecycle
        } catch {
            cleanupSuccessLifecycle = previousLifecycle
            lifecycle = .cleanupRequired
            issue = cleanupIssue(error)
        }
        candidateContext = nil
        executableCandidate = nil
        await reconcileCurrentAuthentication()
    }

    public func commitExecutableCandidate() async {
        guard let context = candidateContext else {
            issue = runtimeIssue(SessionModelError.noExecutableCandidate)
            return
        }
        guard context.authentication.isAuthenticated == true else {
            issue = runtimeIssue(SessionModelError.candidateAuthenticationRequired)
            return
        }
        let previousLifecycle = lifecycle
        lifecycle = .validatingExecutable
        activity = "Saving executable preference"
        issue = nil

        do {
            let settings = try await dependencies.persistence.updateSelectedVibePath(context.executable.url)
            selectedVibePath = settings.selectedVibePath
        } catch {
            let cleanupError: (any Error)?
            do {
                try await disposeCandidateVerified(context.owner)
                cleanupError = nil
            } catch {
                cleanupError = error
            }
            candidateContext = nil
            executableCandidate = nil
            if cleanupError != nil {
                cleanupSuccessLifecycle = previousLifecycle
                lifecycle = .cleanupRequired
            } else {
                lifecycle = previousLifecycle
            }
            activity = nil
            await reconcileCurrentAuthentication()
            issue = if let cleanupError {
                cleanupIssue(cleanupError)
            } else {
                .init(
                    kind: .persistence,
                    title: "Executable was not changed",
                    message: String(describing: error),
                    actions: [.retry]
                )
            }
            return
        }

        // Persistence is the irrevocable commit point. Old state is invalidated and disposed
        // before the replacement owner is published, as required by ADR 0003.
        lifecycle = .swappingExecutable
        activity = "Replacing Vibe process owners"
        let sessionOwner = invalidateRuntime(clearPresentation: true)
        let oldAuthOwner = authOwner
        authOwner = nil
        authOwnerExecutablePath = nil
        authentication = .unknown
        if let cleanupError = await disposeOwners(
            session: sessionOwner,
            authentication: oldAuthOwner,
            candidate: nil
        ) {
            _ = try? await disposeCandidateVerified(context.owner)
            candidateContext = nil
            executableCandidate = nil
            cleanupSuccessLifecycle = .swapFailed
            lifecycle = .swapFailed
            issue = .init(
                kind: .swapFailed,
                title: "Executable swap cleanup failed",
                message: "The new path is committed and old owners will not be revived. \(cleanupError)",
                actions: hasPendingCleanup ? [.retryCleanup, .quit] : [.retryCandidate, .quit]
            )
            activity = nil
            return
        }

        do {
            let promotion = try await context.owner.promote()
            candidateContext = nil
            executableCandidate = nil

            // One MainActor publication installs the new owner and unloaded presentation.
            authOwner = promotion.owner
            authOwnerExecutablePath = context.executable.url.path
            authentication = .status(promotion.snapshot.status)
            trust = .unknown
            pendingPermissions.removeAll()
            reducer.reset()
            sessionState = reducer.state
            knownGoodSnapshot = nil
            configurationOptions = []
            configurationState = .effectiveFromVibe
            lifecycle = .unloaded
            issue = nil
        } catch {
            _ = try? await disposeCandidateVerified(context.owner)
            candidateContext = nil
            executableCandidate = nil
            authOwner = nil
            authOwnerExecutablePath = nil
            authentication = .unknown
            cleanupSuccessLifecycle = .swapFailed
            lifecycle = .swapFailed
            issue = .init(
                kind: .swapFailed,
                title: "Executable swap failed",
                message: "The new path is committed and old process owners will not be revived. \(error)",
                actions: hasPendingCleanup ? [.retryCleanup, .quit] : [.retryCandidate, .quit]
            )
        }
        activity = nil
    }

    public func resetLocalMetadata() async {
        lifecycle = .replacingThread
        activity = "Stopping processes before metadata recovery"
        issue = nil
        let sessionOwner = invalidateRuntime(clearPresentation: true)
        let owner = authOwner
        authOwner = nil
        authOwnerExecutablePath = nil
        let candidate = candidateContext?.owner
        candidateContext = nil
        executableCandidate = nil
        authentication = .unknown

        if let cleanupError = await disposeOwners(
            session: sessionOwner,
            authentication: owner,
            candidate: candidate
        ) {
            cleanupSuccessLifecycle = .unloaded
            lifecycle = .cleanupRequired
            issue = .init(
                kind: .cleanupRequired,
                title: "Metadata reset did not run",
                message: "All process owners must stop before the database can be moved. \(cleanupError)",
                actions: [.retryCleanup, .quit]
            )
        } else {
            do {
            let result = try await dependencies.persistence.resetLocalMetadata()
            lastRecoveryBackupURL = result.backupDirectory
            selectedThread = result.restoredSnapshot.selectedThread
            selectedVibePath = result.restoredSnapshot.settings.selectedVibePath
            lifecycle = .unloaded
            } catch {
                lifecycle = .failed(String(describing: error))
                issue = databaseIssue(error)
            }
        }
        activity = nil
    }

    public func shutdown() async {
        let sessionOwner = invalidateRuntime(clearPresentation: true)
        let owner = authOwner
        authOwner = nil
        authOwnerExecutablePath = nil
        let candidate = candidateContext?.owner
        candidateContext = nil
        executableCandidate = nil
        authentication = .unknown
        let priorCleanupError = await retryPendingCleanupOwners()
        let ownerCleanupError = await disposeOwners(
            session: sessionOwner,
            authentication: owner,
            candidate: candidate
        )
        if priorCleanupError == nil, ownerCleanupError == nil {
            do {
            try await dependencies.persistence.close()
            lifecycle = .unloaded
            } catch {
                lifecycle = .failed(String(describing: error))
                issue = databaseIssue(error)
            }
        } else {
            cleanupSuccessLifecycle = .unloaded
            lifecycle = .cleanupRequired
            issue = cleanupIssue(priorCleanupError ?? ownerCleanupError!)
        }
    }
}

// MARK: - Runtime preparation and replay

private extension SessionModel {
    private func prepareRuntime(executable: VibeExecutable, cwd: URL) async throws -> ActiveRuntime {
        let authSnapshot = try await ensureAuthentication(executable: executable, requireReady: true)
        authentication = .status(authSnapshot.status)

        let owner = dependencies.makeRuntime(executable, cwd)
        let started = try await owner.start()
        let active = ActiveRuntime(
            id: dependencies.makeUUID(),
            owner: owner,
            generation: started.generation,
            sessionID: nil
        )
        activeRuntime = active
        startConsumers(for: active)

        do {
            let trustStatus = try await owner.repositoryTrustStatus(cwd: cwd)
            guard activeRuntime?.id == active.id else { throw SessionModelError.staleRuntime }
            trust = .status(trustStatus)
            guard trustStatus.state == .trusted else {
                let staleOwner = invalidateRuntime(clearPresentation: true)
                try await stopVerified(staleOwner)
                trust = .status(trustStatus)
                throw SessionModelError.repositoryTrustRequired
            }
            return active
        } catch {
            if activeRuntime?.id == active.id {
                let staleOwner = invalidateRuntime(clearPresentation: true)
                try await stopVerified(staleOwner)
            }
            throw error
        }
    }

    func ensureAuthentication(
        executable: VibeExecutable,
        requireReady: Bool
    ) async throws -> VibeAuthenticationSnapshot {
        if authOwnerExecutablePath != executable.url.path {
            if let authOwner { try await disposeAuthVerified(authOwner) }
            authOwner = dependencies.makeAuthenticationOwner(executable)
            authOwnerExecutablePath = executable.url.path
        }
        guard let authOwner else { throw SessionModelError.authenticationRequired }
        let snapshot = try await authOwner.refresh()
        if requireReady, snapshot.status.isAuthenticated != true {
            authentication = .status(snapshot.status)
            throw SessionModelError.authenticationRequired
        }
        return snapshot
    }

    func reconcileCurrentAuthentication() async {
        guard let authOwner else {
            authentication = .unknown
            return
        }
        do {
            let snapshot = try await authOwner.refresh()
            authentication = .status(snapshot.status)
        } catch {
            authentication = .unknown
        }
    }

    func loadSelectedThread(
        runtimeID: UUID,
        expectedConfiguration: (String, JSONValue)?,
        preserveKnownGoodOnFailure: Bool
    ) async throws {
        guard let active = activeRuntime, active.id == runtimeID else {
            throw SessionModelError.staleRuntime
        }
        let metadata = try requireSelectedThread()
        lifecycle = .loadingHistory
        activity = "Loading saved history"
        loadContext = LoadContext(
            runtimeID: runtimeID,
            generation: active.generation,
            loadAttemptID: nil,
            reducer: SessionReducer(),
            failure: nil
        )
        let result = try await active.owner.loadSession(
            sessionID: metadata.thread.vibeSessionID,
            cwd: URL(filePath: metadata.environment.cwd, directoryHint: .isDirectory)
        )
        guard activeRuntime?.id == runtimeID else { throw SessionModelError.staleRuntime }
        try bindAndValidate(result.barrier, runtimeID: runtimeID)
        try await waitForBarrier(result.barrier, runtimeID: runtimeID)
        // Drain receive-loop work already queued on the main actor, then ask the runtime for its
        // authoritative health before publishing staged history.
        await Task.yield()
        if let failure = await active.owner.failure() { throw failure }
        if let failure = loadContext?.failure { throw failure }

        let options = try decodeConfigurationOptions(result.configurationOptions)
        if let expectedConfiguration {
            let effective = options.first(where: { $0.id == expectedConfiguration.0 })?.currentValue
            guard effective == expectedConfiguration.1 else {
                throw SessionModelError.configurationNotEffective(
                    optionID: expectedConfiguration.0,
                    requested: expectedConfiguration.1,
                    effective: effective
                )
            }
        }
        guard var completed = loadContext,
              completed.runtimeID == runtimeID,
              completed.failure == nil
        else {
            throw loadContext?.failure ?? SessionModelError.staleRuntime
        }

        // Plans are runtime-transient even if a future Vibe happens to replay one.
        completed.reducer.unloadRuntime()
        let publishedReducer = completed.reducer
        loadContext = nil
        activeRuntime?.sessionID = metadata.thread.vibeSessionID

        // History, configuration, and lifecycle are published together after the full barrier.
        reducer = publishedReducer
        sessionState = publishedReducer.state
        configurationOptions = options
        configurationState = .effectiveFromVibe
        knownGoodSnapshot = nil
        lifecycle = .idle
        issue = nil
        if !preserveKnownGoodOnFailure { knownGoodSnapshot = nil }
    }

    func bindAndValidate(_ barrier: ReplayBarrier, runtimeID: UUID) throws {
        guard var context = loadContext,
              context.runtimeID == runtimeID,
              context.generation == barrier.runtimeGeneration
        else { throw SessionModelError.replayAttemptMismatch }
        if let attempt = context.loadAttemptID, attempt != barrier.loadAttemptID {
            context.failure = .replayAttemptMismatch
            loadContext = context
            throw SessionModelError.replayAttemptMismatch
        }
        context.loadAttemptID = barrier.loadAttemptID
        loadContext = context
    }

    func waitForBarrier(_ barrier: ReplayBarrier, runtimeID: UUID) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            guard let context = loadContext, context.runtimeID == runtimeID else {
                throw SessionModelError.staleRuntime
            }
            if let failure = context.failure { throw failure }
            if context.reducer.state.lastAppliedSequence >= barrier.throughSequence { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw SessionModelError.replayBarrierTimeout
    }

    private func startConsumers(for active: ActiveRuntime) {
        updateTask?.cancel()
        requestTask?.cancel()
        diagnosticTask?.cancel()

        updateTask = Task { [weak self, owner = active.owner, id = active.id] in
            let stream = await owner.updates()
            for await envelope in stream {
                guard !Task.isCancelled else { return }
                self?.consume(envelope, runtimeID: id)
            }
            self?.runtimeStreamEnded(runtimeID: id)
        }
        requestTask = Task { [weak self, owner = active.owner, id = active.id] in
            let stream = await owner.incomingRequests()
            for await request in stream {
                guard !Task.isCancelled else { return }
                await self?.consume(request, runtimeID: id)
            }
        }
        diagnosticTask = Task { [weak self, owner = active.owner, id = active.id] in
            let stream = await owner.diagnostics()
            for await diagnostic in stream {
                guard !Task.isCancelled else { return }
                if case let .failure(error) = diagnostic {
                    await self?.diagnoseRuntimeFailure(error, runtimeID: id)
                }
            }
        }
    }

    func consume(_ envelope: EventEnvelope<SessionUpdate>, runtimeID: UUID) {
        guard let active = activeRuntime,
              active.id == runtimeID,
              active.generation == envelope.runtimeGeneration
        else { return }

        if var context = loadContext, context.runtimeID == runtimeID {
            switch envelope.deliveryPhase {
            case .loadPending:
                guard let attemptID = envelope.loadAttemptID else {
                    context.failure = .replayAttemptMismatch
                    loadContext = context
                    return
                }
                if let boundAttempt = context.loadAttemptID, boundAttempt != attemptID {
                    context.failure = .replayAttemptMismatch
                    loadContext = context
                    return
                }
                context.loadAttemptID = attemptID
                context.reducer.reduce(envelope)
                loadContext = context
            case .postLoadGuard:
                if envelope.payload.isReducerBoundHistory {
                    context.failure = .replayAttemptMismatch
                    loadContext = context
                }
            case .live:
                context.failure = .replayAttemptMismatch
                loadContext = context
            }
            return
        }

        switch envelope.deliveryPhase {
        case .live:
            reducer.reduce(envelope)
            sessionState = reducer.state
        case .postLoadGuard where envelope.payload.isReducerBoundHistory:
            Task { await handleRuntimeFailure(
                ACPTransportError.postResponseHistory(kind: envelope.payload.kind),
                preserveKnownGood: false
            ) }
        default:
            break
        }
    }

    func consume(_ request: IncomingACPRequest, runtimeID: UUID) async {
        guard let active = activeRuntime, active.id == runtimeID,
              let permission = PermissionRequest(request),
              !resolvedPermissionIDs.contains(permission.requestID)
        else { return }

        if permission.sessionID != active.sessionID || lifecycle != .prompting {
            do {
                try await active.owner.respondToPermissionCancellation(id: permission.requestID)
                guard activeRuntime?.id == runtimeID else { return }
                resolvedPermissionIDs.insert(permission.requestID)
            } catch {
                await handleRuntimeFailure(error, preserveKnownGood: false)
            }
            return
        }
        guard !pendingPermissions.contains(where: { $0.id == permission.requestID }) else { return }
        pendingPermissions.append(.init(request: permission))
    }

    func runtimeStreamEnded(runtimeID: UUID) {
        guard activeRuntime?.id == runtimeID else { return }
        if var context = loadContext, context.runtimeID == runtimeID {
            context.failure = .replayStreamEnded
            loadContext = context
            return
        }
        Task { await handleRuntimeFailure(
            SessionModelError.replayStreamEnded,
            preserveKnownGood: false
        ) }
    }

    func diagnoseRuntimeFailure(_ error: ACPTransportError, runtimeID: UUID) async {
        guard activeRuntime?.id == runtimeID else { return }
        if var context = loadContext, context.runtimeID == runtimeID {
            context.failure = .replayStreamEnded
            loadContext = context
            return
        }
        await handleRuntimeFailure(error, preserveKnownGood: false)
    }
}

// MARK: - Disposal, failure, and presentation helpers

private extension SessionModel {
    func invalidateRuntime(
        clearPresentation: Bool,
        keepKnownGood: Bool = false
    ) -> (any SessionRuntime)? {
        let owner = activeRuntime?.owner
        activeRuntime = nil
        loadContext = nil
        updateTask?.cancel()
        requestTask?.cancel()
        diagnosticTask?.cancel()
        updateTask = nil
        requestTask = nil
        diagnosticTask = nil
        pendingPermissions.removeAll()
        resolvedPermissionIDs.removeAll()
        if clearPresentation { clearRuntimePresentation(keepKnownGood: keepKnownGood) }
        return owner
    }

    func clearRuntimePresentation(keepKnownGood: Bool) {
        reducer.reset()
        sessionState = reducer.state
        configurationOptions = []
        trust = .unknown
        pendingPermissions.removeAll()
        if !keepKnownGood { knownGoodSnapshot = nil }
    }

    func stopVerified(_ owner: (any SessionRuntime)?) async throws {
        guard let owner else {
            if hasPendingCleanup { throw SessionModelError.cleanupOutstanding }
            return
        }
        do {
            try verifyCleanup(await owner.stop())
            pendingRuntimeCleanup = nil
        } catch {
            pendingRuntimeCleanup = owner
            throw error
        }
    }

    func disposeAuthVerified(_ owner: (any SessionAuthenticationOwner)?) async throws {
        guard let owner else { return }
        do {
            try verifyCleanup(try await owner.dispose())
            pendingAuthCleanup = nil
        } catch {
            pendingAuthCleanup = owner
            throw error
        }
    }

    func disposeCandidateVerified(_ owner: (any SessionAuthenticationCandidate)?) async throws {
        guard let owner else { return }
        do {
            try verifyCleanup(try await owner.dispose())
            pendingCandidateCleanup = nil
        } catch {
            pendingCandidateCleanup = owner
            throw error
        }
    }

    func disposeOwners(
        session: (any SessionRuntime)?,
        authentication: (any SessionAuthenticationOwner)?,
        candidate: (any SessionAuthenticationCandidate)?
    ) async -> (any Error)? {
        var firstError: (any Error)?
        do { try await stopVerified(session) }
        catch { firstError = firstError ?? error }
        do { try await disposeAuthVerified(authentication) }
        catch { firstError = firstError ?? error }
        do { try await disposeCandidateVerified(candidate) }
        catch { firstError = firstError ?? error }
        return firstError
    }

    func retryPendingCleanupOwners() async -> (any Error)? {
        var firstError: (any Error)?
        if let owner = pendingRuntimeCleanup {
            do {
                try verifyCleanup(try await owner.retryCleanup())
                pendingRuntimeCleanup = nil
            } catch {
                firstError = firstError ?? error
            }
        }
        if let owner = pendingAuthCleanup {
            do {
                try verifyCleanup(try await owner.retryCleanup())
                pendingAuthCleanup = nil
            } catch {
                firstError = firstError ?? error
            }
        }
        if let owner = pendingCandidateCleanup {
            do {
                try verifyCleanup(try await owner.retryCleanup())
                pendingCandidateCleanup = nil
            } catch {
                firstError = firstError ?? error
            }
        }
        return firstError
    }

    func verifyCleanup(_ report: ProcessCleanupReport?) throws {
        guard let report else { return }
        guard report.survivors.isEmpty else {
            throw SessionModelError.cleanupIncomplete(report.survivors)
        }
    }

    func failLoadOrPreparation(_ error: any Error, preserveKnownGood: Bool) async {
        let blockedTrust = trust
        let owner = invalidateRuntime(clearPresentation: true, keepKnownGood: preserveKnownGood)
        do {
            try await stopVerified(owner)
            if preserveKnownGood {
                lifecycle = .reloadRequired
            } else {
                lifecycle = .failed(String(describing: error))
            }
            if let modelError = error as? SessionModelError,
               modelError == .repositoryTrustRequired
            {
                trust = blockedTrust
            }
            issue = runtimeIssue(error)
        } catch {
            cleanupSuccessLifecycle = preserveKnownGood ? .reloadRequired : .unloaded
            lifecycle = .cleanupRequired
            issue = cleanupIssue(error)
        }
    }

    func handleRuntimeFailure(_ error: any Error, preserveKnownGood: Bool) async {
        guard !handlingRuntimeFailure else { return }
        handlingRuntimeFailure = true
        defer { handlingRuntimeFailure = false }
        await failLoadOrPreparation(error, preserveKnownGood: preserveKnownGood)
        activity = nil
    }

    func decodeConfigurationOptions(_ values: [JSONValue]) throws -> [VibeConfigurationOption] {
        try values.map { value in
            guard let option = VibeConfigurationOption(value) else {
                throw VibeAdapterError.invalidConfigurationResponse
            }
            return option
        }
    }

    func requireSelectedThread() throws -> SavedThreadMetadata {
        guard let selectedThread else { throw SessionModelError.noSavedThread }
        return selectedThread
    }

    func publishCandidatePresentation() {
        guard let candidateContext else {
            executableCandidate = nil
            return
        }
        executableCandidate = .init(
            executable: candidateContext.executable,
            authentication: candidateContext.authentication,
            pendingSignIn: candidateContext.pendingSignIn
        )
    }

    func runtimeIssue(_ error: any Error) -> SessionModelIssue {
        let threadActions: [SessionRecoveryAction] = selectedThread == nil
            ? []
            : [.retry, .resetRuntime, .removeSavedThread]
        if error is RepositoryValidationError {
            return .init(
                kind: .repositoryUnavailable,
                title: "Repository unavailable",
                message: String(describing: error),
                actions: selectedThread == nil ? [] : [.retry, .removeSavedThread]
            )
        }
        if let modelError = error as? SessionModelError {
            switch modelError {
            case .authenticationRequired, .candidateAuthenticationRequired:
                return .init(
                    kind: .authenticationRequired,
                    title: "Authentication required",
                    message: modelError.description,
                    actions: threadActions
                )
            case .repositoryTrustRequired:
                return .init(
                    kind: .trustRequired,
                    title: "Repository trust required",
                    message: "Choose one of Vibe’s advertised trust decisions to continue. LeChaton does not invent or persist that decision.",
                    actions: []
                )
            default:
                break
            }
        }
        return .init(
            kind: .runtime,
            title: "Session runtime failed",
            message: String(describing: error),
            actions: threadActions
        )
    }

    func cleanupIssue(_ error: any Error) -> SessionModelIssue {
        .init(
            kind: .cleanupRequired,
            title: "Process cleanup required",
            message: String(describing: error),
            actions: [.retryCleanup, .quit]
        )
    }

    func databaseIssue(_ error: any Error) -> SessionModelIssue {
        if let persistenceError = error as? PersistenceStoreError,
           case .schemaTooNew = persistenceError
        {
            return .init(
                kind: .database,
                title: "LeChaton must be updated",
                message: String(describing: error),
                actions: [.updateApplication, .revealDatabase, .quit]
            )
        }
        return .init(
            kind: .database,
            title: "Local metadata could not be opened",
            message: String(describing: error),
            actions: [.retry, .revealDatabase, .exportDiagnostic, .resetLocalMetadata]
        )
    }

    func isFailed(_ lifecycle: SessionLifecycle) -> Bool {
        if case .failed = lifecycle { return true }
        return false
    }

    func isRepositoryTrustRequired(_ error: any Error) -> Bool {
        (error as? SessionModelError) == .repositoryTrustRequired
    }
}
