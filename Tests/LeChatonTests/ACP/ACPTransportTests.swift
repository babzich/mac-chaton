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

    @Test("Session listing decodes standard cursor pages and preserves unknown fields")
    func paginatedSessionList() async throws {
        let transport = try makeTransport(scenario: "session-list-paginated")
        _ = try await transport.start()
        _ = try await withTimeout { try await transport.initialize() }

        let first = try await withTimeout {
            try await transport.listSessions(cwd: repositoryURL)
        }
        #expect(first.sessions.map(\.sessionID) == ["another-session"])
        #expect(first.sessions[0].cwd == repositoryURL.path)
        #expect(first.sessions[0].additionalDirectories.isEmpty)
        #expect(first.sessions[0].title == "Another session")
        #expect(first.sessions[0].updatedAt == "2030-01-01T00:00:00Z")
        #expect(first.sessions[0].metadata?["itemFuture"]?.boolValue == true)
        #expect(first.sessions[0].raw["futureItemField"]?.intValue == 1)
        #expect(first.nextCursor == "page-2")
        #expect(first.metadata?["pageFuture"]?.boolValue == true)
        #expect(first.raw["futurePageField"]?.intValue == 2)

        let second = try await withTimeout {
            try await transport.listSessions(cwd: repositoryURL, cursor: first.nextCursor)
        }
        #expect(second.sessions.map(\.sessionID) == ["persisted-session"])
        #expect(second.nextCursor == nil)

        _ = await transport.stop(gracePeriod: .milliseconds(50))
    }

    @Test("Malformed known session-list fields fail without rejecting unknown fields")
    func malformedSessionList() async throws {
        let transport = try makeTransport(scenario: "malformed-session-list")
        _ = try await transport.start()
        _ = try await withTimeout { try await transport.initialize() }

        await #expect(throws: ACPTransportError.invalidResponse(method: "session/list")) {
            _ = try await transport.listSessions(cwd: repositoryURL)
        }
        _ = await transport.stop(gracePeriod: .milliseconds(50))
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

    @Test("Permission queue admission failure remains retryable and commits once")
    func permissionAdmissionFailureIsRetryable() async throws {
        let transport = makePermissionBackpressureTransport()
        _ = try await transport.start()
        _ = try await withTimeout { try await transport.initialize() }
        let session = try await withTimeout { try await transport.newSession(cwd: repositoryURL) }
        var requests = await transport.incomingRequests().makeAsyncIterator()
        let prompt = Task {
            try await transport.prompt(sessionID: session.sessionID, text: "Queue pressure")
        }
        let incoming = try #require(await requests.next())
        let permission = try #require(PermissionRequest(incoming))

        // The shell agent stops reading after issuing the permission. One large
        // active frame plus this queued frame fills the two-frame writer bound.
        let blockingWrite = Task {
            try await transport.sendNotification(
                method: "_test/blocking",
                params: .object([
                    "payload": .string(String(repeating: "x", count: 1_024 * 1_024)),
                ])
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        let queuedWrite = Task {
            try await transport.sendNotification(method: "_test/queued")
        }
        try await Task.sleep(for: .milliseconds(25))

        do {
            try await transport.respondToPermission(
                id: permission.requestID,
                selectedOptionID: permission.options[0].optionID
            )
            Issue.record("Expected bounded writer admission to fail")
        } catch let error as ACPTransportError {
            guard case .outgoingQueueFull(maximumFrames: 2, maximumBytes: 4 * 1_024 * 1_024) = error else {
                Issue.record("Expected outgoing queue admission failure, got \(error)")
                _ = await transport.stop(gracePeriod: .milliseconds(20))
                return
            }
        }
        #expect(await transport.failure() == nil)

        // Removing only the queued frame creates one admission slot. The same
        // permission ID must still be retryable after the failed admission.
        queuedWrite.cancel()
        _ = await queuedWrite.result
        try await transport.respondToPermission(
            id: permission.requestID,
            selectedOptionID: permission.options[0].optionID
        )

        // The accepted retry consumes the ID. With the queue full again, a
        // duplicate would throw if it attempted to enqueue a second response.
        try await transport.respondToPermission(
            id: permission.requestID,
            selectedOptionID: permission.options[0].optionID
        )

        let report = try await withTimeout {
            await transport.stop(gracePeriod: .milliseconds(20))
        }
        #expect(report?.survivors.isEmpty == true)
        _ = await blockingWrite.result
        _ = await prompt.result
    }

    @Test("Writer stop joins the active worker before returning")
    func writerStopJoinsActiveWorker() async throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        let probe = BlockingWriteProbe()
        let writer = try ACPStandardInputWriter(
            fileDescriptor: pipe.fileHandleForWriting.fileDescriptor,
            maximumFrameBytes: 1_024,
            maximumPendingFrames: 2,
            maximumPendingBytes: 2_048,
            writeOperation: { data, _, _ in probe.write(byteCount: data.count) }
        )
        _ = try writer.enqueue(Data("frame\n".utf8), timeout: .seconds(1))
        _ = try await eventually { probe.hasStarted ? true : nil }

        let completion = WriterStopCompletion()
        let stop = Task {
            await writer.stop()
            await completion.markFinished()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await completion.isFinished == false)

        probe.release()
        try await withTimeout { await stop.value }
        #expect(await completion.isFinished)
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

    @Test("A missing load response reaches its deadline and fails the runtime")
    func loadResponseDeadline() async throws {
        let transport = try makeTransport(
            scenario: "no-load-response",
            responseTimeout: .milliseconds(100)
        )
        _ = try await transport.start()
        _ = try await withTimeout { try await transport.initialize() }

        do {
            _ = try await withTimeout(timeout: .seconds(1)) {
                try await transport.loadSession(sessionID: "saved-session", cwd: repositoryURL)
            }
            Issue.record("Expected session/load to time out")
        } catch let error as ACPTransportError {
            #expect(error == .responseTimedOut(method: "session/load"))
        }
        #expect(await transport.failure() == .responseTimedOut(method: "session/load"))
        _ = await transport.stop(gracePeriod: .milliseconds(50))
    }

    @Test("Configuration and authentication extension requests have finite response deadlines")
    func extensionResponseDeadlines() async throws {
        for (scenario, method) in [
            ("no-config-response", "session/set_config_option"),
            ("no-auth-response", "_auth/status"),
        ] {
            let transport = try makeTransport(
                scenario: scenario,
                responseTimeout: .seconds(1)
            )
            _ = try await transport.start()
            _ = try await withTimeout { try await transport.initialize() }

            do {
                _ = try await withTimeout(timeout: .seconds(1)) {
                    try await transport.request(
                        method: method,
                        params: .object([:]),
                        responseTimeout: .milliseconds(100)
                    )
                }
                Issue.record("Expected \(method) to time out")
            } catch let error as ACPTransportError {
                #expect(error == .responseTimedOut(method: method))
            }
            #expect(await transport.failure() == .responseTimedOut(method: method))
            _ = await transport.stop(gracePeriod: .milliseconds(50))
        }
    }

    @Test("Standard-input backpressure times out without starving the transport actor")
    func standardInputBackpressure() async throws {
        let transport = try makeTransport(
            scenario: "stdin-backpressure",
            standardInputWriteTimeout: .milliseconds(100),
            responseTimeout: .seconds(1)
        )
        let generation = try await transport.start()
        _ = try await withTimeout { try await transport.initialize() }

        let send = Task {
            try await transport.sendNotification(
                method: "_fake/large_notification",
                params: .object([
                    "payload": .string(String(repeating: "x", count: 1_024 * 1_024)),
                ])
            )
        }

        // This actor hop must remain responsive while the detached writer is
        // waiting for the child's full stdin pipe to become writable.
        let observedGeneration = try await withTimeout(timeout: .milliseconds(250)) {
            await transport.currentGeneration()
        }
        #expect(observedGeneration == generation)

        do {
            try await withTimeout(timeout: .seconds(1)) { try await send.value }
            Issue.record("Expected bounded standard-input write timeout")
        } catch let error as ACPTransportError {
            #expect(error == .writeTimedOut)
        }
        #expect(try await eventually { await transport.failure() } == .writeTimedOut)
        _ = await transport.stop(gracePeriod: .milliseconds(50))
    }

    @Test("Oversized outgoing frames are rejected before entering the writer queue")
    func outgoingFrameCap() async throws {
        let transport = try makeTransport(scenario: "standard", maximumFrameBytes: 256)
        _ = try await transport.start()

        do {
            try await transport.sendNotification(
                method: "_fake/oversized",
                params: .object(["payload": .string(String(repeating: "x", count: 512))])
            )
            Issue.record("Expected outgoing frame cap")
        } catch let error as ACPTransportError {
            #expect(error == .outgoingFrameTooLarge(maximumBytes: 256))
        }
        #expect(await transport.failure() == nil)
        _ = await transport.stop(gracePeriod: .milliseconds(50))
    }

    @Test("Frames larger than the pending-byte budget are rejected without trapping")
    func outgoingPendingByteCap() async throws {
        let transport = try makeTransport(
            scenario: "standard",
            maximumFrameBytes: 1_024,
            maximumPendingOutgoingBytes: 256
        )
        _ = try await transport.start()

        do {
            try await transport.sendNotification(
                method: "_fake/pending-byte-cap",
                params: .object(["payload": .string(String(repeating: "x", count: 512))])
            )
            Issue.record("Expected pending-byte queue cap")
        } catch let error as ACPTransportError {
            #expect(error == .outgoingQueueFull(maximumFrames: 64, maximumBytes: 256))
        }
        #expect(await transport.failure() == nil)
        _ = await transport.stop(gracePeriod: .milliseconds(50))
    }

    private var repositoryURL: URL {
        URL(filePath: FileManager.default.currentDirectoryPath)
    }

    private func makeTransport(
        scenario: String,
        maximumFrameBytes: Int = 16 * 1_024 * 1_024,
        maximumPendingOutgoingFrames: Int = 64,
        maximumPendingOutgoingBytes: Int = 32 * 1_024 * 1_024,
        standardInputWriteTimeout: Duration = .seconds(5),
        responseTimeout: Duration = .seconds(60),
        promptResponseTimeout: Duration = .seconds(600)
    ) throws -> ACPTransport {
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
            ],
            maximumFrameBytes: maximumFrameBytes,
            maximumPendingOutgoingFrames: maximumPendingOutgoingFrames,
            maximumPendingOutgoingBytes: maximumPendingOutgoingBytes,
            standardInputWriteTimeout: standardInputWriteTimeout,
            responseTimeout: responseTimeout,
            promptResponseTimeout: promptResponseTimeout
        ))
    }

    private func makePermissionBackpressureTransport() -> ACPTransport {
        let script = #"""
        IFS= read -r initialize
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
        IFS= read -r new_session
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"queue-session"}}'
        IFS= read -r prompt
        printf '%s\n' '{"jsonrpc":"2.0","id":"permission-queue","method":"session/request_permission","params":{"sessionId":"queue-session","toolCall":{"toolCallId":"tool-queue"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"}]}}'
        kill -STOP $$
        """#
        return ACPTransport(configuration: .init(
            executableURL: URL(filePath: "/bin/sh"),
            arguments: ["-c", script],
            workingDirectory: repositoryURL,
            environment: [
                "HOME": NSHomeDirectory(),
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ],
            maximumFrameBytes: 2 * 1_024 * 1_024,
            maximumPendingOutgoingFrames: 2,
            maximumPendingOutgoingBytes: 4 * 1_024 * 1_024,
            standardInputWriteTimeout: .seconds(10)
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

private final class BlockingWriteProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false

    var hasStarted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return started
    }

    func write(byteCount: Int) -> Int {
        condition.lock()
        started = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
        return byteCount
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private actor WriterStopCompletion {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}

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
