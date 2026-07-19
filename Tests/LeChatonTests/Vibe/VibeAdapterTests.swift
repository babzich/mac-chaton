import Foundation
import Testing
@testable import LeChatonCore

@Suite("Vibe adapter and authentication owner", .serialized)
struct VibeAdapterTests {
    @Test("Authentication owner launches lazily, validates exact compatibility, and fully disposes")
    func lazyValidatedOwner() async throws {
        let coordinator = try makeCoordinator(scenario: "standard")
        #expect(await coordinator.rootProcessIdentity() == nil)

        let snapshot = try await withTimeout { try await coordinator.refresh() }
        #expect(snapshot.compatibility.initialization.protocolVersion == 1)
        #expect(snapshot.compatibility.initialization.agentInfo?.version == "2.21.0")
        #expect(snapshot.compatibility.initialization.agentCapabilities["loadSession"]?.boolValue == true)
        #expect(snapshot.status.state == .authenticated)

        let root = try #require(await coordinator.rootProcessIdentity())
        #expect(ProcessInspector.isAlive(root))
        let report = try await coordinator.dispose()
        #expect(report?.survivors.isEmpty == true)
        #expect(!ProcessInspector.isAlive(root))
        #expect(await coordinator.rootProcessIdentity() == nil)
        #expect(try await coordinator.dispose() == nil)
    }

    @Test("Every auth process rejects the wrong Vibe version, agent, capability, and protocol")
    func exactCompatibility() async throws {
        let scenarios = [
            "wrong-version",
            "wrong-agent",
            "missing-load-capability",
            "missing-list-capability",
            "protocol-two",
        ]
        for scenario in scenarios {
            let coordinator = try makeCoordinator(scenario: scenario)
            do {
                _ = try await withTimeout { try await coordinator.compatibility() }
                Issue.record("Expected \(scenario) compatibility to fail")
            } catch is VibeCompatibilityError {
                // Expected after initialize succeeds but exact Vibe validation fails.
            } catch let error as ACPTransportError where scenario == "protocol-two" {
                #expect(error == .unsupportedProtocolVersion(expected: 1, reported: 2))
            }
            #expect(await coordinator.rootProcessIdentity() == nil)
            _ = try await coordinator.dispose()
        }
    }

    @Test("Delegated start and complete remain on the same lazy authentication process")
    func processBoundDelegatedAuthentication() async throws {
        let coordinator = try makeCoordinator(scenario: "auth-unauthenticated")
        #expect(try await coordinator.authenticationStatus().state == .unauthenticated)
        let root = try #require(await coordinator.rootProcessIdentity())

        let attempt = try await withTimeout {
            try await coordinator.startDelegatedAuthentication()
        }
        #expect(attempt.id == "fake-attempt-\(root.pid)")
        #expect(attempt.signInURL.scheme == "https")
        #expect(await coordinator.rootProcessIdentity() == root)
        #expect(await coordinator.pendingDelegatedAuthentication()?.id == attempt.id)

        do {
            _ = try await coordinator.completeDelegatedAuthentication(attemptID: "another-attempt")
            Issue.record("Expected a mismatched attempt to be rejected locally")
        } catch let error as AuthCoordinatorError {
            #expect(error == .attemptMismatch(expected: attempt.id, received: "another-attempt"))
        }
        #expect(await coordinator.rootProcessIdentity() == root)

        let status = try await withTimeout {
            try await coordinator.completeDelegatedAuthentication(attemptID: attempt.id)
        }
        #expect(status.state == .authenticated)
        #expect(await coordinator.pendingDelegatedAuthentication() == nil)
        #expect(await coordinator.rootProcessIdentity() == root)
        _ = try await coordinator.dispose()
        #expect(!ProcessInspector.isAlive(root))
    }

    @Test("Authentication status sees only its explicitly injected provider key")
    func providerAuthenticationEnvironment() async throws {
        var environment = try fakeProcessOptions(scenario: "auth-provider-environment").environment ?? [:]
        environment["LECHATON_TEST_PROVIDER_KEY"] = "provider-secret"
        let authenticated = AuthCoordinator(
            executable: try fakeVibeExecutable(),
            neutralWorkingDirectory: repositoryURL,
            processOptions: .init(
                arguments: ["--scenario", "auth-provider-environment"],
                environment: environment
            )
        )
        #expect(try await authenticated.authenticationStatus().state == .authenticated)
        _ = try await authenticated.dispose()

        let missing = try makeCoordinator(scenario: "auth-provider-environment")
        #expect(try await missing.authenticationStatus().state == .unauthenticated)
        _ = try await missing.dispose()
    }

    @Test("Auth status decoding tolerates legacy, unknown, and future response shapes")
    func tolerantAuthenticationStatus() {
        let authoritative = VibeAuthenticationStatus(raw: .object([
            "authenticated": .bool(false),
            "authState": .string("future_state"),
            "signOutAvailable": .bool(true),
            "future": .array([.integer(1)]),
        ]))
        #expect(authoritative.state == .unauthenticated)
        #expect(authoritative.reportedState == "future_state")
        #expect(authoritative.signOutAvailable == true)

        #expect(VibeAuthenticationStatus(raw: .object([
            "isAuthenticated": .bool(true),
        ])).state == .authenticated)
        #expect(VibeAuthenticationStatus(raw: .object([
            "status": .string("authenticated"),
        ])).state == .authenticated)
        #expect(VibeAuthenticationStatus(raw: .object([
            "authState": .string("future_state"),
        ])).state == .unknown(rawValue: "future_state"))
        #expect(VibeAuthenticationStatus(raw: .string("future-shape")).state == .unknown(rawValue: nil))
    }

    @Test("Persisted-session lookup follows ACP pagination and matches both ID and cwd")
    func persistedSessionLookup() async throws {
        let adapter = VibeAdapter()
        let validated = try await adapter.launchValidatedAuthenticationProcess(
            executable: try fakeVibeExecutable(),
            workingDirectory: repositoryURL,
            processOptions: try fakeProcessOptions(scenario: "session-list-paginated")
        )

        let exists = try await adapter.persistedSessionExists(
            sessionID: "persisted-session",
            cwd: repositoryURL,
            transport: validated.transport
        )
        let missing = try await adapter.persistedSessionExists(
            sessionID: "missing-session",
            cwd: repositoryURL,
            transport: validated.transport
        )
        let wrongCWD = try await adapter.persistedSessionExists(
            sessionID: "persisted-session",
            cwd: repositoryURL.appending(path: "different-worktree", directoryHint: .isDirectory),
            transport: validated.transport
        )
        #expect(exists)
        #expect(!missing)
        #expect(!wrongCWD)

        let report = await validated.transport.stop(gracePeriod: .milliseconds(50))
        #expect(report?.survivors.isEmpty == true)
    }

    @Test("Persisted-session lookup rejects a repeated pagination cursor")
    func repeatedSessionListCursor() async throws {
        let adapter = VibeAdapter()
        let validated = try await adapter.launchValidatedAuthenticationProcess(
            executable: try fakeVibeExecutable(),
            workingDirectory: repositoryURL,
            processOptions: try fakeProcessOptions(scenario: "session-list-cursor-loop")
        )

        await #expect(throws: VibeAdapterError.invalidSessionListPagination("same-cursor")) {
            _ = try await adapter.persistedSessionExists(
                sessionID: "missing-session",
                cwd: repositoryURL,
                transport: validated.transport
            )
        }
        _ = await validated.transport.stop(gracePeriod: .milliseconds(50))
    }

    @Test("Persisted-session lookup rejects pagination beyond its finite page limit")
    func sessionListPageLimit() async throws {
        let adapter = VibeAdapter()
        let validated = try await adapter.launchValidatedAuthenticationProcess(
            executable: try fakeVibeExecutable(),
            workingDirectory: repositoryURL,
            processOptions: try fakeProcessOptions(scenario: "session-list-unique-cursors")
        )

        await #expect(throws: VibeAdapterError.sessionListPageLimitExceeded(
            maximumPages: VibeAdapter.maximumSessionListPages
        )) {
            _ = try await adapter.persistedSessionExists(
                sessionID: "missing-session",
                cwd: repositoryURL,
                transport: validated.transport
            )
        }
        _ = await validated.transport.stop(gracePeriod: .milliseconds(50))
    }

    @Test("Only Vibe's exact requested-ID missing-session response is specialized")
    func exactMissingSessionMapping() async throws {
        let adapter = VibeAdapter()
        let requestedID = "missing-session"
        let exact = try await adapter.launchValidatedAuthenticationProcess(
            executable: try fakeVibeExecutable(),
            workingDirectory: repositoryURL,
            processOptions: try fakeProcessOptions(scenario: "session-not-found")
        )
        await #expect(throws: VibeAdapterError.savedSessionUnavailable(requestedID)) {
            _ = try await adapter.loadSession(
                sessionID: requestedID,
                cwd: repositoryURL,
                transport: exact.transport
            )
        }
        _ = await exact.transport.stop(gracePeriod: .milliseconds(50))

        for scenario in [
            "session-not-found-wrong-data",
            "session-not-found-extra-data",
            "session-not-found-wrong-message",
        ] {
            let mismatched = try await adapter.launchValidatedAuthenticationProcess(
                executable: try fakeVibeExecutable(),
                workingDirectory: repositoryURL,
                processOptions: try fakeProcessOptions(scenario: scenario)
            )
            do {
                _ = try await adapter.loadSession(
                    sessionID: requestedID,
                    cwd: repositoryURL,
                    transport: mismatched.transport
                )
                Issue.record("Expected \(scenario) to remain a generic ACP failure")
            } catch is VibeAdapterError {
                Issue.record("Expected \(scenario) to remain a generic ACP failure")
            } catch let error as ACPTransportError {
                guard case .responseError = error else {
                    Issue.record("Expected responseError for \(scenario), got \(error)")
                    _ = await mismatched.transport.stop(gracePeriod: .milliseconds(50))
                    continue
                }
            }
            _ = await mismatched.transport.stop(gracePeriod: .milliseconds(50))
        }
    }

    @Test("Repository trust decoding preserves Vibe options and tolerates future status values")
    func tolerantRepositoryTrustStatus() async throws {
        let adapter = VibeAdapter()
        let validated = try await adapter.launchValidatedAuthenticationProcess(
            executable: try fakeVibeExecutable(),
            workingDirectory: repositoryURL,
            processOptions: try fakeProcessOptions(scenario: "trust-untrusted")
        )
        let status = try await withTimeout {
            try await adapter.repositoryTrustStatus(
                cwd: repositoryURL,
                transport: validated.transport
            )
        }
        #expect(status.state == .untrusted)
        #expect(status.reportedState == "untrusted")
        #expect(status.options == [.string("trust_repo"), .string("decline")])
        #expect(status.details?["futureField"]?.boolValue == true)
        #expect(!status.allowsSessionStart)
        let trusted = try await withTimeout {
            try await adapter.applyRepositoryTrustDecision(
                cwd: repositoryURL,
                decision: "trust_repo",
                transport: validated.transport
            )
        }
        #expect(trusted.state == .trusted)
        #expect(trusted.allowsSessionStart)
        #expect(try await adapter.repositoryTrustStatus(
            cwd: repositoryURL,
            transport: validated.transport
        ).state == .trusted)
        _ = await validated.transport.stop(gracePeriod: .milliseconds(50))

        let sessionTrusted = VibeRepositoryTrustStatus(raw: .object([
            "trust_status": .string("session"),
            "futureField": .integer(1),
        ]))
        #expect(sessionTrusted.state == .trusted)
        #expect(sessionTrusted.allowsSessionStart)
        let noDecisionNeeded = VibeRepositoryTrustStatus(raw: .object([
            "trust_status": .string("untrusted"),
            "details": .null,
        ]))
        #expect(noDecisionNeeded.state == .untrusted)
        #expect(noDecisionNeeded.allowsSessionStart)
        #expect(!VibeRepositoryTrustStatus(raw: .object([
            "trust_status": .string("untrusted"),
        ])).allowsSessionStart)
        #expect(!VibeRepositoryTrustStatus(raw: .object([
            "trust_status": .string("untrusted"),
            "details": .array([]),
        ])).allowsSessionStart)
        let future = VibeRepositoryTrustStatus(raw: .object([
            "trust_status": .string("future_trust_state"),
            "options": .array([.object(["id": .string("future")])]),
        ]))
        #expect(future.state == .unknown(rawValue: "future_trust_state"))
        #expect(future.options == [.object(["id": .string("future")])])
        #expect(!future.allowsSessionStart)
        #expect(VibeRepositoryTrustStatus(raw: .string("future-shape")).state == .unknown(rawValue: nil))
    }

    @Test("Private candidate is inert before validation and disposes its complete process owner")
    func privateCandidateDisposal() async throws {
        let adapter = VibeAdapter()
        let executable = try fakeVibeExecutable()
        let candidate = adapter.makeAuthenticationCandidate(
            executable: executable,
            neutralWorkingDirectory: repositoryURL,
            processOptions: try fakeProcessOptions(scenario: "standard")
        )
        #expect(await candidate.rootProcessIdentity() == nil)
        let snapshot = try await withTimeout { try await candidate.refresh() }
        #expect(snapshot.status.state == .authenticated)
        let root = try #require(await candidate.rootProcessIdentity())

        let report = try await candidate.dispose()
        #expect(report?.survivors.isEmpty == true)
        #expect(!ProcessInspector.isAlive(root))
        #expect(try await candidate.dispose() == nil)
    }

    @Test("Candidate transfer revalidates and preserves exactly one process owner")
    func privateCandidateTransfer() async throws {
        let adapter = VibeAdapter()
        let candidate = adapter.makeAuthenticationCandidate(
            executable: try fakeVibeExecutable(),
            neutralWorkingDirectory: repositoryURL,
            processOptions: try fakeProcessOptions(scenario: "standard")
        )
        _ = try await candidate.refresh()
        let root = try #require(await candidate.rootProcessIdentity())
        let (owner, snapshot) = try await candidate.takeValidatedOwner()
        #expect(snapshot.status.state == .authenticated)
        #expect(await candidate.rootProcessIdentity() == nil)
        #expect(await owner.rootProcessIdentity() == root)
        _ = try await owner.dispose()
        #expect(!ProcessInspector.isAlive(root))
    }

    @Test("Candidate transfer refuses an owner whose final auth refresh is no longer ready")
    func privateCandidateTransferRequiresFinalAuthentication() async throws {
        let adapter = VibeAdapter()
        let candidate = adapter.makeAuthenticationCandidate(
            executable: try fakeVibeExecutable(),
            neutralWorkingDirectory: repositoryURL,
            processOptions: try fakeProcessOptions(scenario: "auth-drops-before-promotion")
        )
        let initial = try await candidate.refresh()
        #expect(initial.status.state == .authenticated)
        let root = try #require(await candidate.rootProcessIdentity())

        do {
            _ = try await candidate.takeValidatedOwner()
            Issue.record("Expected final unauthenticated status to block promotion")
        } catch let error as AuthCoordinatorError {
            #expect(error == .authenticationRequiredAtPromotion)
        }

        // Failed promotion retains candidate ownership so the process can be
        // deterministically disposed instead of leaking an unpublished owner.
        #expect(await candidate.rootProcessIdentity() == root)
        let report = try await candidate.dispose()
        #expect(report?.survivors.isEmpty == true)
        #expect(!ProcessInspector.isAlive(root))
    }

    @Test("Configuration option models preserve supported and unknown kinds")
    func configurationOptionDecoding() throws {
        let select = try #require(VibeConfigurationOption(.object([
            "id": .string("model"),
            "name": .string("Model"),
            "type": .string("select"),
            "currentValue": .string("small"),
            "options": .array([
                .object(["value": .string("small"), "name": .string("Small")]),
                .object(["value": .string("large"), "future": .bool(true)]),
            ]),
            "futureField": .integer(7),
        ])))
        #expect(select.kind == .select)
        #expect(select.values == [.string("small"), .string("large")])
        #expect(select.alternateValue == .string("large"))

        let singleValue = try #require(VibeConfigurationOption(.object([
            "id": .string("single-model"),
            "type": .string("select"),
            "currentValue": .string("only"),
            "options": .array([
                .object(["value": .string("only")]),
            ]),
        ])))
        #expect(singleValue.values == [.string("only")])
        #expect(singleValue.alternateValue == nil)

        let boolean = try #require(VibeConfigurationOption(.object([
            "id": .string("enabled"),
            "type": .string("boolean"),
            "currentValue": .bool(true),
        ])))
        #expect(boolean.kind == .boolean)
        #expect(boolean.values == [.bool(false), .bool(true)])
        #expect(boolean.alternateValue == .bool(false))

        let future = try #require(VibeConfigurationOption(.object([
            "id": .string("future"),
            "type": .string("slider"),
            "currentValue": .integer(3),
            "future": .object([:]),
        ])))
        #expect(future.kind == .unknown("slider"))
        #expect(future.values.isEmpty)
        #expect(future.alternateValue == nil)

        #expect(VibeConfigurationOption(.object([
            "id": .string("broken-select"),
            "type": .string("select"),
            "currentValue": .string("one"),
        ])) == nil)
    }

    @Test("Configuration writes use the adapter and return freshly decoded effective options")
    func configurationWrite() async throws {
        let adapter = VibeAdapter()
        let validated = try await adapter.launchValidatedAuthenticationProcess(
            executable: try fakeVibeExecutable(),
            workingDirectory: repositoryURL,
            processOptions: try fakeProcessOptions(scenario: "standard")
        )
        defer {
            Task { _ = await validated.transport.stop(gracePeriod: .milliseconds(50)) }
        }
        let session = try await withTimeout {
            try await validated.transport.newSession(cwd: repositoryURL)
        }
        let write = try await withTimeout {
            try await adapter.setConfigurationOption(
                sessionID: session.sessionID,
                optionID: "model",
                kind: .select,
                value: .string("fake-model-2"),
                transport: validated.transport
            )
        }
        let model = try #require(write.options.first(where: { $0.id == "model" }))
        #expect(model.currentValue == .string("fake-model-2"))
        #expect(model.alternateValue == .string("fake-model"))
        let report = await validated.transport.stop(gracePeriod: .milliseconds(50))
        #expect(report?.survivors.isEmpty == true)
    }

    @Test("Configuration write acknowledgements may omit options because fresh load is authoritative")
    func configurationWriteWithoutOptions() async throws {
        for scenario in ["config-empty-response", "config-null-response"] {
            let adapter = VibeAdapter()
            let validated = try await adapter.launchValidatedAuthenticationProcess(
                executable: try fakeVibeExecutable(),
                workingDirectory: repositoryURL,
                processOptions: try fakeProcessOptions(scenario: scenario)
            )
            let session = try await withTimeout {
                try await validated.transport.newSession(cwd: repositoryURL)
            }
            let write = try await withTimeout {
                try await adapter.setConfigurationOption(
                    sessionID: session.sessionID,
                    optionID: "model",
                    kind: .select,
                    value: .string("fake-model-2"),
                    transport: validated.transport
                )
            }
            #expect(write.options.isEmpty)
            let report = await validated.transport.stop(gracePeriod: .milliseconds(50))
            #expect(report?.survivors.isEmpty == true)
        }
    }

    private var repositoryURL: URL {
        URL(filePath: FileManager.default.currentDirectoryPath)
    }

    private func makeCoordinator(scenario: String) throws -> AuthCoordinator {
        AuthCoordinator(
            executable: try fakeVibeExecutable(),
            neutralWorkingDirectory: repositoryURL,
            processOptions: try fakeProcessOptions(scenario: scenario)
        )
    }

    private func fakeVibeExecutable() throws -> VibeExecutable {
        .init(url: try fakeExecutableURL(), source: .explicit)
    }

    private func fakeProcessOptions(scenario: String) throws -> VibeProcessOptions {
        let executable = try fakeExecutableURL()
        return .init(
            arguments: ["--scenario", scenario],
            environment: [
                "HOME": NSHomeDirectory(),
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "DYLD_FRAMEWORK_PATH": executable.deletingLastPathComponent().path,
            ]
        )
    }

    private func fakeExecutableURL() throws -> URL {
        var candidates: [URL] = []
        if let products = ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"] {
            candidates.append(URL(filePath: products).appending(path: "FakeACPAgent"))
        }
        let testBundle = Bundle(for: VibeAdapterTestBundleMarker.self).bundleURL
        candidates.append(testBundle.deletingLastPathComponent().appending(path: "FakeACPAgent"))
        candidates.append(testBundle.appending(path: "Contents/MacOS/FakeACPAgent"))
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw VibeAdapterTestError.fakeAgentNotFound(candidates.map(\.path))
    }

    private func withTimeout<T: Sendable>(
        timeout: Duration = .seconds(2),
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw VibeAdapterTestError.timeout
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}

private final class VibeAdapterTestBundleMarker {}

private enum VibeAdapterTestError: Error, CustomStringConvertible {
    case fakeAgentNotFound([String])
    case timeout

    var description: String {
        switch self {
        case let .fakeAgentNotFound(paths):
            "FakeACPAgent not found; checked \(paths.joined(separator: ", "))"
        case .timeout: "Timed out waiting for Vibe adapter"
        }
    }
}
