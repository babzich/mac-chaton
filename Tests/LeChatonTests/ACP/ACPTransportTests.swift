import Foundation
import Testing
@testable import LeChatonCore

@Suite("ACP transport with fake process", .serialized)
struct ACPTransportTests {
    @Test("Load returns a barrier after replay and unknown updates acknowledge through reduction")
    func loadBarrierAndUnknownUpdate() async throws {
        let transport = try makeTransport(scenario: "standard")
        _ = try await transport.start()
        let initialization = try await withTimeout { try await transport.initialize() }
        #expect(initialization.protocolVersion == 1)

        let stream = await transport.updates()
        var iterator = stream.makeAsyncIterator()
        let loaded = try await withTimeout {
            try await transport.loadSession(sessionID: "saved-session", cwd: repositoryURL)
        }
        var reducer = SessionReducer()
        while reducer.state.lastAppliedSequence < loaded.barrier.throughSequence {
            guard let event = await iterator.next() else {
                Issue.record("Update stream ended before the replay barrier")
                break
            }
            #expect(event.runtimeGeneration == loaded.barrier.runtimeGeneration)
            #expect(event.loadAttemptID == loaded.barrier.loadAttemptID)
            #expect(event.deliveryPhase == .loadPending)
            reducer.reduce(event)
        }

        #expect(loaded.barrier.throughSequence == 5)
        #expect(reducer.state.lastAppliedSequence == loaded.barrier.throughSequence)
        #expect(reducer.state.messages.map(\.text) == ["Earlier question", "Earlier answer"])
        #expect(reducer.state.reasoning.map(\.text) == ["Earlier reasoning"])
        #expect(reducer.state.orderedToolCalls.map(\.id) == ["tool-1"])
        #expect(reducer.state.unknownUpdateCount == 1)
        let report = try await withTimeout {
            await transport.stop(gracePeriod: .milliseconds(50))
        }
        #expect(report?.survivors.isEmpty == true)
    }

    @Test("A history envelope after the load response fails the runtime")
    func replayAfterResponseFails() async throws {
        let transport = try makeTransport(scenario: "replay-after-response")
        _ = try await transport.start()
        _ = try await withTimeout { try await transport.initialize() }
        _ = try? await withTimeout {
            try await transport.loadSession(sessionID: "saved-session", cwd: repositoryURL)
        }

        let failure = try await eventually {
            await transport.failure()
        }
        guard case .postResponseHistory = failure else {
            Issue.record("Expected post-response replay failure, got \(String(describing: failure))")
            _ = await transport.stop(gracePeriod: .milliseconds(50))
            return
        }
        _ = await transport.stop(gracePeriod: .milliseconds(50))
    }

    @Test("Permission selection preserves request ID and completes the prompt")
    func permissionResponse() async throws {
        let transport = try makeTransport(scenario: "standard")
        _ = try await transport.start()
        _ = try await withTimeout { try await transport.initialize() }
        let newSession = try await withTimeout { try await transport.newSession(cwd: repositoryURL) }
        let sessionID = newSession.sessionID
        var requests = await transport.incomingRequests().makeAsyncIterator()

        let promptTask = Task { try await transport.prompt(sessionID: sessionID, text: "Test permission") }
        let incoming = try #require(await requests.next())
        let permission = try #require(PermissionRequest(incoming))
        #expect(permission.requestID == .string("permission-1"))
        #expect(permission.options.map(\.optionID) == ["allow-once", "reject-once"])
        try await transport.respondToPermission(
            id: permission.requestID,
            selectedOptionID: permission.options[0].optionID
        )
        let result = try await withTimeout { try await promptTask.value }
        #expect(result.stopReason == .endTurn)
        _ = await transport.stop(gracePeriod: .milliseconds(50))
    }

    @Test("Cancellation and permission cancellation are idempotent")
    func cancellationIsIdempotent() async throws {
        let transport = try makeTransport(scenario: "standard")
        _ = try await transport.start()
        _ = try await withTimeout { try await transport.initialize() }
        let newSession = try await withTimeout { try await transport.newSession(cwd: repositoryURL) }
        let sessionID = newSession.sessionID
        var requests = await transport.incomingRequests().makeAsyncIterator()
        let promptTask = Task { try await transport.prompt(sessionID: sessionID, text: "Test cancellation") }
        _ = try #require(await requests.next())

        #expect(try await transport.cancelPrompt(sessionID: sessionID))
        #expect(try await !transport.cancelPrompt(sessionID: sessionID))
        let result = try await withTimeout { try await promptTask.value }
        #expect(result.stopReason == .cancelled)
        let report = await transport.stop(gracePeriod: .milliseconds(50))
        #expect(report?.survivors.isEmpty == true)
    }

    @Test("Graceful cancellation waits for descendants and keeps the runtime reusable")
    func gracefulCancellationWaitsForDescendants() async throws {
        let transport = try makeTransport(scenario: "descendant-graceful")
        _ = try await transport.start()
        _ = try await withTimeout { try await transport.initialize() }
        let newSession = try await withTimeout { try await transport.newSession(cwd: repositoryURL) }
        var requests = await transport.incomingRequests().makeAsyncIterator()

        let promptTask = Task {
            try await transport.prompt(sessionID: newSession.sessionID, text: "Spawn a short child")
        }
        _ = try #require(await requests.next())
        let trackedAtCancellation = try await eventually {
            let live = await transport.snapshotProcessTree()
            return live.count >= 2 ? live : nil
        }

        #expect(try await transport.cancelPrompt(
            sessionID: newSession.sessionID,
            gracefulPeriod: .seconds(1),
            terminationGracePeriod: .milliseconds(20),
            rescanInterval: .milliseconds(5),
            killConfirmationPeriod: .milliseconds(50)
        ))
        #expect(try await withTimeout { try await promptTask.value }.stopReason == .cancelled)

        let root = try #require(await transport.rootProcessIdentity())
        #expect(await transport.liveProcessTree() == [root])
        #expect(await transport.failure() == nil)
        for child in trackedAtCancellation where child != root {
            #expect(!ProcessInspector.isAlive(child))
        }

        // A successful graceful cancellation retains the same process for another prompt.
        let followUp = Task {
            try await transport.prompt(sessionID: newSession.sessionID, text: "Follow up")
        }
        let followUpIncoming = try #require(await requests.next())
        let followUpPermission = try #require(PermissionRequest(followUpIncoming))
        try await transport.respondToPermission(
            id: followUpPermission.requestID,
            selectedOptionID: followUpPermission.options[0].optionID
        )
        #expect(try await withTimeout { try await followUp.value }.stopReason == .endTurn)
        _ = await transport.stop(gracePeriod: .milliseconds(20))
    }

    @Test("A resistant descendant forces complete runtime cleanup")
    func resistantDescendantForcesCleanup() async throws {
        let transport = try makeTransport(scenario: "descendant-resistant")
        _ = try await transport.start()
        _ = try await withTimeout { try await transport.initialize() }
        let newSession = try await withTimeout { try await transport.newSession(cwd: repositoryURL) }
        var requests = await transport.incomingRequests().makeAsyncIterator()

        let promptTask = Task {
            try await transport.prompt(sessionID: newSession.sessionID, text: "Spawn a resistant child")
        }
        _ = try #require(await requests.next())
        let tracked = try await eventually {
            let live = await transport.snapshotProcessTree()
            return live.count >= 2 ? live : nil
        }

        do {
            _ = try await transport.cancelPrompt(
                sessionID: newSession.sessionID,
                gracefulPeriod: .milliseconds(20),
                terminationGracePeriod: .milliseconds(20),
                rescanInterval: .milliseconds(5),
                killConfirmationPeriod: .milliseconds(100)
            )
            Issue.record("Expected forced cancellation to fail the runtime")
        } catch let error as ACPTransportError {
            switch error {
            case .cancellationForced, .processExited, .endOfFile:
                break
            default:
                Issue.record("Unexpected cancellation error: \(error)")
            }
        }

        _ = try? await withTimeout { try await promptTask.value }
        #expect(await transport.failure() != nil)
        for identity in tracked {
            #expect(!ProcessInspector.isAlive(identity))
        }
        _ = await transport.stop(gracePeriod: .milliseconds(20))
    }

    @Test("Permission requests arriving after cancellation receive the cancelled outcome")
    func latePermissionIsCancelled() async throws {
        let transport = try makeTransport(scenario: "late-permission-on-cancel")
        _ = try await transport.start()
        _ = try await withTimeout { try await transport.initialize() }
        let newSession = try await withTimeout { try await transport.newSession(cwd: repositoryURL) }
        var requests = await transport.incomingRequests().makeAsyncIterator()
        let diagnosticTask = Task {
            for await diagnostic in await transport.diagnostics() {
                if diagnostic == .ignoredNotification(method: "_fake/late_permission_cancelled") {
                    return true
                }
            }
            return false
        }

        let promptTask = Task {
            try await transport.prompt(sessionID: newSession.sessionID, text: "Cancel permissions")
        }
        _ = try #require(await requests.next())
        #expect(try await transport.cancelPrompt(
            sessionID: newSession.sessionID,
            gracefulPeriod: .seconds(1),
            terminationGracePeriod: .milliseconds(20),
            rescanInterval: .milliseconds(5),
            killConfirmationPeriod: .milliseconds(50)
        ))
        #expect(try await withTimeout { try await promptTask.value }.stopReason == .cancelled)
        #expect(try await withTimeout { await diagnosticTask.value })
        _ = await transport.stop(gracePeriod: .milliseconds(20))
    }

    @Test("Explicit forced cleanup always makes the runtime terminal")
    func forceCleanupIsTerminal() async throws {
        let transport = try makeTransport(scenario: "standard")
        _ = try await transport.start()
        _ = try await withTimeout { try await transport.initialize() }
        let root = try #require(await transport.rootProcessIdentity())

        let report = try await transport.forceCleanup(gracePeriod: .milliseconds(20))

        #expect(report.survivors.isEmpty)
        #expect(await transport.failure() != nil)
        #expect(!ProcessInspector.isAlive(root))
        _ = await transport.stop(gracePeriod: .milliseconds(20))
    }

    @Test("Initialize rejects an ACP protocol other than one")
    func unsupportedProtocol() async throws {
        let transport = try makeTransport(scenario: "protocol-two")
        _ = try await transport.start()
        do {
            _ = try await withTimeout { try await transport.initialize() }
            Issue.record("Expected unsupported protocol failure")
        } catch let error as ACPTransportError {
            #expect(error == .unsupportedProtocolVersion(expected: 1, reported: 2))
        }
        _ = await transport.stop(gracePeriod: .milliseconds(50))
    }

    @Test("A malformed optional field in the matching load response fails the runtime")
    func malformedLoadResponse() async throws {
        let transport = try makeTransport(scenario: "malformed-load-response")
        _ = try await transport.start()
        _ = try await withTimeout { try await transport.initialize() }

        do {
            _ = try await withTimeout {
                try await transport.loadSession(sessionID: "saved-session", cwd: repositoryURL)
            }
            Issue.record("Expected malformed load response failure")
        } catch let error as ACPTransportError {
            #expect(error == .invalidResponse(method: "session/load"))
        }
        #expect(await transport.failure() == .invalidResponse(method: "session/load"))
        _ = await transport.stop(gracePeriod: .milliseconds(50))
    }

    @Test("Malformed required fields in a known replay update fail the load")
    func malformedKnownReplay() async throws {
        let transport = try makeTransport(scenario: "malformed-known-replay")
        _ = try await transport.start()
        _ = try await withTimeout { try await transport.initialize() }

        do {
            _ = try await withTimeout {
                try await transport.loadSession(sessionID: "saved-session", cwd: repositoryURL)
            }
            Issue.record("Expected malformed replay failure")
        } catch let error as ACPTransportError {
            guard case let .protocolViolation(message) = error else {
                Issue.record("Expected protocol violation, got \(error)")
                _ = await transport.stop(gracePeriod: .milliseconds(50))
                return
            }
            #expect(message.contains("Malformed known session update: agent_message_chunk"))
        }
        _ = await transport.stop(gracePeriod: .milliseconds(50))
    }

    @Test("Unknown replay updates and response fields remain forward compatible")
    func unknownLoadContent() async throws {
        let transport = try makeTransport(scenario: "unknown-only-load")
        _ = try await transport.start()
        _ = try await withTimeout { try await transport.initialize() }
        var updates = await transport.updates().makeAsyncIterator()

        let loaded = try await withTimeout {
            try await transport.loadSession(sessionID: "saved-session", cwd: repositoryURL)
        }
        let event = try #require(await updates.next())
        #expect(loaded.barrier.throughSequence == event.sequence)
        #expect(event.deliveryPhase == .loadPending)
        guard case let .unknown(kind, raw) = event.payload else {
            Issue.record("Expected unknown replay update")
            _ = await transport.stop(gracePeriod: .milliseconds(50))
            return
        }
        #expect(kind == "future_update")
        #expect(raw["malformedIfKnown"]?.intValue == 42)
        #expect(loaded.raw["futureResponseField"]?["preserved"]?.boolValue == true)
        _ = await transport.stop(gracePeriod: .milliseconds(50))
    }

    private var repositoryURL: URL {
        URL(filePath: FileManager.default.currentDirectoryPath)
    }

    private func makeTransport(scenario: String) throws -> ACPTransport {
        let executable = try fakeExecutableURL()
        return ACPTransport(configuration: .init(
            executableURL: executable,
            arguments: ["--scenario", scenario],
            workingDirectory: repositoryURL,
            environment: [
                "HOME": NSHomeDirectory(),
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                // The fake is a test-only command-line product linked to the core framework.
                "DYLD_FRAMEWORK_PATH": executable.deletingLastPathComponent().path,
            ]
        ))
    }

    private func fakeExecutableURL() throws -> URL {
        var candidates: [URL] = []
        if let products = ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"] {
            candidates.append(URL(filePath: products).appending(path: "FakeACPAgent"))
        }
        let testBundle = Bundle(for: TestBundleMarker.self).bundleURL
        candidates.append(testBundle.deletingLastPathComponent().appending(path: "FakeACPAgent"))
        candidates.append(testBundle.appending(path: "Contents/MacOS/FakeACPAgent"))

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw TestSupportError.fakeAgentNotFound(candidates.map(\.path))
    }

    private func eventually<T: Sendable>(
        timeout: Duration = .seconds(2),
        operation: @escaping @Sendable () async -> T?
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                while true {
                    if let value = await operation() { return value }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TestSupportError.timeout
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    private func withTimeout<T: Sendable>(
        timeout: Duration = .seconds(2),
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TestSupportError.timeout
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}

private final class TestBundleMarker {}

private enum TestSupportError: Error, CustomStringConvertible {
    case fakeAgentNotFound([String])
    case timeout

    var description: String {
        switch self {
        case let .fakeAgentNotFound(paths): "FakeACPAgent not found; checked \(paths.joined(separator: ", "))"
        case .timeout: "Timed out waiting for transport state"
        }
    }
}
