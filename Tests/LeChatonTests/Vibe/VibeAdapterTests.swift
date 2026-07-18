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
        let trusted = try await withTimeout {
            try await adapter.applyRepositoryTrustDecision(
                cwd: repositoryURL,
                decision: "trust_repo",
                transport: validated.transport
            )
        }
        #expect(trusted.state == .trusted)
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
        let future = VibeRepositoryTrustStatus(raw: .object([
            "trust_status": .string("future_trust_state"),
            "options": .array([.object(["id": .string("future")])]),
        ]))
        #expect(future.state == .unknown(rawValue: "future_trust_state"))
        #expect(future.options == [.object(["id": .string("future")])])
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
