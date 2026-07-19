import Foundation
import LeChatonCore

struct ProbeRuntime: Sendable {
    let executable: VibeExecutable
    let cwd: URL
    let transport: ACPTransport
    let generation: UUID
    let consumer: ReplayConsumer
    let permissionTask: Task<Void, Never>
    let permissionState: PermissionResponseState

    static func start(
        executable: VibeExecutable,
        cwd: URL,
        permissionPolicy: PermissionPolicy
    ) async throws -> Self {
        let transport = ACPTransport(configuration: .init(
            executableURL: executable.url,
            workingDirectory: cwd
        ))
        let generation = try await transport.start()
        let consumer = ReplayConsumer(transport: transport, generation: generation)
        let permissionState = PermissionResponseState(policy: permissionPolicy)
        let permissionTask = Task {
            let requests = await transport.incomingRequests()
            for await request in requests {
                guard let permission = PermissionRequest(request) else { continue }
                await permissionState.answer(permission, through: transport)
            }
        }

        do {
            let initialization = try await withTimeout(.seconds(20), operationName: "initialize") {
                try await transport.initialize(
                    clientName: "LeChaton ACPProbe",
                    clientCapabilities: .object([
                        "fs": .object([
                            "readTextFile": .bool(false),
                            "writeTextFile": .bool(false),
                        ]),
                        "terminal": .bool(false),
                        "session": .object([
                            "configOptions": .object([
                                "boolean": .object([:]),
                            ]),
                        ]),
                        "plan": .object([:]),
                        "auth": .object([
                            "terminal": .bool(false),
                        ]),
                        "_meta": .object(["browser-auth-delegated": .bool(true)]),
                    ])
                )
            }
            _ = try VibeCompatibility(executable: executable, initialization: initialization)
            guard initialization.agentCapabilities["loadSession"]?.boolValue == true else {
                throw ProbeError.compatibility("Vibe did not negotiate session/load capability")
            }
            guard initialization.agentCapabilities["promptCapabilities"]?.objectValue != nil else {
                throw ProbeError.compatibility("Vibe did not report prompt capabilities")
            }
            return .init(
                executable: executable,
                cwd: cwd,
                transport: transport,
                generation: generation,
                consumer: consumer,
                permissionTask: permissionTask,
                permissionState: permissionState
            )
        } catch {
            permissionTask.cancel()
            consumer.cancel()
            _ = await transport.stop()
            throw error
        }
    }

    func requireReady() async throws {
        let auth = try await withTimeout(.seconds(10), operationName: "authentication status") {
            try await transport.request(method: "_auth/status", params: .object([:]))
        }
        let authenticated = auth["authenticated"]?.boolValue
            ?? auth["isAuthenticated"]?.boolValue
            ?? auth["status"]?.stringValue.map { $0 == "authenticated" }
        guard authenticated == true else {
            throw ProbeError.compatibility("Vibe authentication is not ready")
        }

        let trust = try await withTimeout(.seconds(10), operationName: "repository trust status") {
            try await transport.request(
                method: "_trust/status",
                params: .object(["cwd": .string(cwd.path)])
            )
        }
        guard VibeRepositoryTrustStatus(raw: trust).allowsSessionStart else {
            throw ProbeError.compatibility(
                "repository has an unresolved trust decision; resolve one of Vibe's advertised choices outside the live gate"
            )
        }
    }

    func load(sessionID: String) async throws -> LoadSessionResult {
        let result = try await withTimeout(.seconds(30), operationName: "session/load") {
            try await transport.loadSession(sessionID: sessionID, cwd: cwd)
        }
        try await waitForBarrierAcknowledgement(
            result.barrier,
            collector: consumer.collector,
            transport: transport
        )
        // Give the post-load guard one scheduling turn to surface an already-buffered violation.
        await Task.yield()
        if let failure = await transport.failure() { throw failure }
        return result
    }

    func prompt(sessionID: String, text: String, timeout: Duration = .seconds(300)) async throws -> PromptResult {
        await consumer.collector.beginPrompt()
        do {
            let result = try await withTimeout(timeout, operationName: "session/prompt") {
                try await transport.prompt(sessionID: sessionID, text: text)
            }
            try await settleConsumer(consumer.collector)
            await consumer.collector.finishPrompt(failed: false)
            return result
        } catch {
            await consumer.collector.finishPrompt(failed: true)
            throw error
        }
    }

    @discardableResult
    func stop() async throws -> ProcessCleanupReport? {
        permissionTask.cancel()
        consumer.cancel()
        let report = await transport.stop()
        if let report, !report.survivors.isEmpty {
            throw ACPTransportError.cleanupFailed(report.survivors)
        }
        return report
    }
}

actor PermissionResponseState {
    private let policy: PermissionPolicy
    private var cancelling = false
    private var ordinal: UInt64 = 0

    init(policy: PermissionPolicy) {
        self.policy = policy
    }

    func beginCancellation() {
        cancelling = true
    }

    func endCancellation() {
        cancelling = false
    }

    func answer(_ permission: PermissionRequest, through transport: ACPTransport) async {
        ordinal += 1
        let chosen: PermissionOption?
        if cancelling {
            chosen = nil
        } else {
            switch policy {
            case .allowOnce:
                chosen = permission.options.first(where: { $0.kind == "allow_once" })
            case .reject:
                chosen = permission.options.first(where: { $0.kind == "reject_once" })
            }
        }

        do {
            if let chosen {
                try await transport.respondToPermission(
                    id: permission.requestID,
                    selectedOptionID: chosen.optionID
                )
                ProbeOutput.emit([
                    "record": .string("permission_response"),
                    "ordinal": .integer(Int64(ordinal)),
                    "outcome": .string(chosen.kind),
                ])
            } else {
                try await transport.respond(
                    id: permission.requestID,
                    result: .object([
                        "outcome": .object(["outcome": .string("cancelled")]),
                    ])
                )
                ProbeOutput.emit([
                    "record": .string("permission_response"),
                    "ordinal": .integer(Int64(ordinal)),
                    "outcome": .string("cancelled"),
                ])
            }
        } catch {
            ProbeOutput.error("permission response failed: \(error)")
        }
    }
}

enum HistoryProbe {
    static func create(
        kind: HistoryKind,
        prompt: String,
        executable: VibeExecutable,
        cwd: URL,
        permissionPolicy: PermissionPolicy
    ) async throws -> HistorySession {
        let runtime = try await ProbeRuntime.start(
            executable: executable,
            cwd: cwd,
            permissionPolicy: permissionPolicy
        )
        do {
            try await runtime.requireReady()
            let session = try await withTimeout(.seconds(30), operationName: "session/new") {
                try await runtime.transport.newSession(cwd: cwd)
            }
            _ = try await runtime.prompt(sessionID: session.sessionID, text: prompt)
            let coverage = await runtime.consumer.collector.observedLiveCoverage()
            switch kind {
            case .text where coverage.messages == 0:
                throw ProbeError.compatibility("text history produced no live message event")
            case .reasoning where coverage.reasoning == 0:
                throw ProbeError.compatibility("reasoning history produced no live reasoning event")
            case .tool where coverage.tools == 0:
                throw ProbeError.compatibility("tool history produced no live tool event")
            case .plan where coverage.plans == 0:
                throw ProbeError.compatibility("plan history produced no live plan event")
            default:
                break
            }
            ProbeOutput.emit([
                "record": .string("history_created"),
                "historyKind": .string(kind.rawValue),
                "sessionId": .string(session.sessionID),
                "messageEvents": .integer(Int64(coverage.messages)),
                "reasoningEvents": .integer(Int64(coverage.reasoning)),
                "toolEvents": .integer(Int64(coverage.tools)),
                "planEvents": .integer(Int64(coverage.plans)),
            ])
            try await runtime.stop()
            return .init(kind: kind, sessionID: session.sessionID)
        } catch {
            _ = try? await runtime.stop()
            throw error
        }
    }

    static func load(
        session: HistorySession,
        traceID: String,
        freshProcessOrdinal: Int,
        followUpPrompt: String?,
        executable: VibeExecutable,
        cwd: URL,
        permissionPolicy: PermissionPolicy
    ) async throws -> ReplayCoverage {
        let runtime = try await ProbeRuntime.start(
            executable: executable,
            cwd: cwd,
            permissionPolicy: permissionPolicy
        )
        do {
            try await runtime.requireReady()
            let loaded = try await runtime.load(sessionID: session.sessionID)
            let (events, barrier, coverage) = try await runtime.consumer.collector.sanitizedRecords(
                traceID: traceID,
                historyKind: session.kind,
                freshProcessOrdinal: freshProcessOrdinal
            )
            events.forEach(ProbeOutput.emit)
            ProbeOutput.emit(barrier)

            if let followUpPrompt {
                guard barrier.acknowledged else {
                    throw ProbeError.compatibility("follow-up was blocked because replay was not acknowledged")
                }
                _ = loaded
                _ = try await runtime.prompt(sessionID: session.sessionID, text: followUpPrompt)
                ProbeOutput.emit([
                    "record": .string("follow_up"),
                    "traceId": .string(traceID),
                    "startedAfterBarrier": .bool(true),
                    "completed": .bool(true),
                ])
            }
            try await runtime.stop()
            return coverage
        } catch {
            _ = try? await runtime.stop()
            throw error
        }
    }
}
