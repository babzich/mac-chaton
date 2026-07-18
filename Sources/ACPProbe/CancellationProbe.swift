import Foundation
import LeChatonCore

enum CancellationProbe {
    static func run(
        sessionID: String,
        prompt: String,
        followUpPrompt: String?,
        cancelAfter: Duration,
        executable: VibeExecutable,
        cwd: URL,
        permissionPolicy: PermissionPolicy
    ) async throws {
        let runtime = try await ProbeRuntime.start(
            executable: executable,
            cwd: cwd,
            permissionPolicy: permissionPolicy
        )
        let completion = PromptCompletionState()
        do {
            try await runtime.requireReady()
            _ = try await runtime.load(sessionID: sessionID)
            await runtime.consumer.collector.beginPrompt()
            let promptTask = Task {
                do {
                    let result = try await runtime.transport.prompt(sessionID: sessionID, text: prompt)
                    await completion.complete(.success(result.stopReason))
                } catch {
                    await completion.complete(.failure(String(describing: error)))
                }
            }

            let root = await runtime.transport.rootProcessIdentity()
            try await Task.sleep(for: cancelAfter)

            let discoveryClock = ContinuousClock()
            let discoveryDeadline = discoveryClock.now.advanced(by: .seconds(30))
            var initialDescendants: Set<ProcessIdentity> = []
            while discoveryClock.now < discoveryDeadline, initialDescendants.isEmpty {
                let snapshot = await runtime.transport.snapshotProcessTree()
                initialDescendants = descendants(in: snapshot, root: root)
                if initialDescendants.isEmpty {
                    if await completion.value() != nil { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            guard !initialDescendants.isEmpty else {
                promptTask.cancel()
                throw ProbeError.compatibility(
                    "cancellation prompt produced no verified descendant within 30 seconds"
                )
            }

            await runtime.permissionState.beginCancellation()
            await runtime.consumer.collector.beginCancellation()
            let cancellationSnapshot = await runtime.transport.snapshotProcessTree()
            initialDescendants = descendants(in: cancellationSnapshot, root: root)
            guard !initialDescendants.isEmpty else {
                promptTask.cancel()
                throw ProbeError.compatibility("verified descendants exited before the cancellation snapshot")
            }
            let sent = try await runtime.transport.cancelPrompt(sessionID: sessionID)
            guard sent else {
                promptTask.cancel()
                throw ProbeError.compatibility("session/cancel was not sent exactly once")
            }
            ProbeOutput.emit([
                "record": .string("cancellation_sent"),
                "initialTrackedDescendants": identitiesJSON(initialDescendants),
                "snapshotBeforeCancel": .bool(true),
            ])

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            var remaining = initialDescendants
            var outcome: PromptCompletion?
            while clock.now < deadline {
                let live = await runtime.transport.liveProcessTree()
                remaining = descendants(in: live, root: root)
                outcome = await completion.value()
                if outcome != nil, remaining.isEmpty { break }
                try await Task.sleep(for: .milliseconds(100))
            }

            if case .success(.cancelled)? = outcome, remaining.isEmpty {
                await runtime.consumer.collector.finishPrompt(failed: false)
                await runtime.permissionState.endCancellation()
                ProbeOutput.emit([
                    "record": .string("cancellation_cleanup"),
                    "mode": .string("graceful"),
                    "promptResponseObserved": .bool(true),
                    "remainingTrackedDescendants": .array([]),
                    "forced": .bool(false),
                ])
                if let followUpPrompt {
                    _ = try await runtime.prompt(sessionID: sessionID, text: followUpPrompt)
                    ProbeOutput.emit([
                        "record": .string("post_cancellation_follow_up"),
                        "runtimeRetained": .bool(true),
                        "completed": .bool(true),
                    ])
                }
                promptTask.cancel()
                try await runtime.stop()
                return
            }

            let report = try await runtime.transport.forceCleanup(gracePeriod: .seconds(2))
            promptTask.cancel()
            ProbeOutput.emit([
                "record": .string("cancellation_cleanup"),
                "mode": .string("forced"),
                "promptResponseObserved": .bool(outcome != nil),
                "remainingBeforeForce": identitiesJSON(remaining),
                "termSignalled": identitiesJSON(report.signalled),
                "forceKilled": identitiesJSON(report.forceKilled),
                "survivors": identitiesJSON(report.survivors),
                "forced": .bool(true),
            ])
            _ = try? await runtime.stop()
            if !report.survivors.isEmpty {
                throw ACPTransportError.cleanupFailed(report.survivors)
            }
            throw ProbeError.compatibility("cancellation required forced process cleanup")
        } catch {
            _ = try? await runtime.stop()
            throw error
        }
    }

    private static func descendants(
        in identities: Set<ProcessIdentity>,
        root: ProcessIdentity?
    ) -> Set<ProcessIdentity> {
        guard let root else { return identities }
        return identities.subtracting([root])
    }

    private static func identitiesJSON(_ identities: Set<ProcessIdentity>) -> JSONValue {
        let sorted = identities.sorted {
            if $0.pid == $1.pid { return $0.processStartTime < $1.processStartTime }
            return $0.pid < $1.pid
        }
        return .array(sorted.map { identity in
            .object([
                "pid": .integer(Int64(identity.pid)),
                "processStartTime": .integer(Int64(bitPattern: identity.processStartTime)),
            ])
        })
    }
}

private enum PromptCompletion: Sendable {
    case success(PromptStopReason)
    case failure(String)
}

private actor PromptCompletionState {
    private var completion: PromptCompletion?

    func complete(_ value: PromptCompletion) {
        guard completion == nil else { return }
        completion = value
    }

    func value() -> PromptCompletion? { completion }
}
